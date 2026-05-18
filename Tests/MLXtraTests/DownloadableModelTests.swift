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
        XCTAssertGreaterThanOrEqual(visionModels.count, AIModel.allCases.count)
    }

    func testEmbeddedVisionModelsIncludeLegacyBuiltInCatalog() {
        let embeddedVisionModels = DownloadableModel.embedded.filter { $0.modality == .vision }
        let expectedVisionModels = AIModel.allCases.map { model in
            DownloadableModel(
                id: model.modelId,
                name: model.displayName,
                subtitle: model.subtitle,
                modelId: model.modelId,
                modality: .vision,
                downloadSizeGB: model.downloadSizeGB,
                estimatedMemoryGB: model.memoryRequirementGB
            )
        }

        for model in expectedVisionModels {
            XCTAssertTrue(embeddedVisionModels.contains(model), "Missing \(model.modelId)")
        }
    }

    func testEmbeddedVisionModelsIncludeAdditionalGemmaAndQwenSizes() {
        let embeddedVisionModelIds = Set(DownloadableModel.embedded
            .filter { $0.modality == .vision }
            .map(\.modelId))

        XCTAssertTrue(embeddedVisionModelIds.contains("mlx-community/gemma-4-e2b-it-4bit"))
        XCTAssertTrue(embeddedVisionModelIds.contains("mlx-community/gemma-4-26b-a4b-it-4bit"))
        XCTAssertTrue(embeddedVisionModelIds.contains("mlx-community/Qwen3.6-27B-4bit"))
        XCTAssertTrue(embeddedVisionModelIds.contains("mlx-community/Qwen3.6-35B-A3B-4bit"))
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

    func testEmbeddedMusicModel() {
        let embedded = DownloadableModel.embedded
        let musicModels = embedded.filter { $0.modality == .music }

        XCTAssertEqual(musicModels.count, 1)
        XCTAssertEqual(musicModels.first?.id, "ACE-Step/acestep-v15-turbo-continuous")
        XCTAssertEqual(musicModels.first?.name, "ACE-Step 1.5 Turbo")
    }

    func testEmbeddedImageModel() {
        let embedded = DownloadableModel.embedded
        let imageModels = embedded.filter { $0.modality == .image }

        XCTAssertEqual(imageModels.count, 1)
        XCTAssertEqual(imageModels.first?.id, "black-forest-labs/FLUX.2-klein-4B")
        XCTAssertEqual(imageModels.first?.modelId, "black-forest-labs/FLUX.2-klein-4B")
    }

    func testEmbeddedModelLookupByModelId() {
        let model = DownloadableModel.embeddedModel(modelId: "black-forest-labs/FLUX.2-klein-4B")

        XCTAssertEqual(model?.name, "FLUX.2-klein-4B")
        XCTAssertEqual(model?.modality, .image)
    }

    func testEmbeddedModelLookupReturnsNilForUnknownModel() {
        XCTAssertNil(DownloadableModel.embeddedModel(modelId: "unknown/model"))
    }

    func testEmbeddedAudioModel() {
        let embedded = DownloadableModel.embedded
        let audioModels = embedded.filter { $0.modality == .audio }

        XCTAssertEqual(audioModels.count, 1)
        XCTAssertEqual(audioModels.first?.id, "kugelaudio/kugelaudio-0-open")
        XCTAssertEqual(audioModels.first?.name, "KugelAudio 0 Open")
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


final class ModelInfoTests: XCTestCase {

    func testModelInfoProperties() {
        let info = ModelInfo(
            name: "Test Model",
            modelId: "org/test-model",
            contextWindow: 8192,
            memoryRequired: 4.0,
            downloadSize: 3.5,
            supportsVision: true
        )

        XCTAssertEqual(info.name, "Test Model")
        XCTAssertEqual(info.modelId, "org/test-model")
        XCTAssertEqual(info.contextWindow, 8192)
        XCTAssertEqual(info.memoryRequired, 4.0)
        XCTAssertEqual(info.downloadSize, 3.5)
        XCTAssertTrue(info.supportsVision)
    }

    func testModelInfoNonVisionSupport() {
        let info = ModelInfo(
            name: "Test Model",
            modelId: "org/test-model",
            contextWindow: 4096,
            memoryRequired: 2.0,
            downloadSize: 2.0,
            supportsVision: false
        )
        XCTAssertFalse(info.supportsVision)
    }
}
