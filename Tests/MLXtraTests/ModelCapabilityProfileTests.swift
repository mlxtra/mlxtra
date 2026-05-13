import XCTest
@testable import MLXtra

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
        XCTAssertEqual(
            store.selectedProfile(
                for: .vision,
                hardwareMemoryGB: 16.0,
                runtimeManifest: testRuntimeManifest
            )?.aiModel,
            .gemma4
        )
    }

    func testPerModeSelectionFallsBackWhenRememberedModelIsInvalidForMode() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let store = ModelSelectionStore(userDefaults: defaults)
        store.setSelectedModelId(AIModel.qwen35.modelId, for: .image)

        XCTAssertEqual(store.selectedProfile(for: .image, hardwareMemoryGB: 16.0)?.modelId, "black-forest-labs/FLUX.2-klein-4B")
    }

    func testPerModeSelectionFallsBackWhenRememberedModelIsTooLargeForHardware() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let store = ModelSelectionStore(userDefaults: defaults)
        store.setSelectedModelId("mlx-community/Qwen3.6-35B-A3B-4bit", for: .vision)

        XCTAssertNotEqual(
            store.selectedProfile(for: .vision, hardwareMemoryGB: 8.0)?.modelId,
            "mlx-community/Qwen3.6-35B-A3B-4bit"
        )
    }

    func testVisibleProfilesHideHeavyGemmaAndQwenVariantsOnLowerMemoryHardware() {
        let visibleModelIds = Set(ModelCapabilityProfile
            .visibleProfiles(for: .vision, hardwareMemoryGB: 8.0)
            .map(\.modelId))

        XCTAssertTrue(visibleModelIds.contains(AIModel.gemma4.modelId))
        XCTAssertFalse(visibleModelIds.contains("mlx-community/gemma-4-26b-a4b-it-4bit"))
        XCTAssertFalse(visibleModelIds.contains("mlx-community/Qwen3.6-27B-4bit"))
        XCTAssertFalse(visibleModelIds.contains("mlx-community/Qwen3.6-35B-A3B-4bit"))
    }

    func testVisibleProfilesIncludeLargeGemmaAndQwenVariantsOnHighMemoryHardware() {
        let visibleModelIds = Set(ModelCapabilityProfile
            .visibleProfiles(for: .vision, hardwareMemoryGB: 32.0)
            .map(\.modelId))

        XCTAssertTrue(visibleModelIds.contains("mlx-community/gemma-4-26b-a4b-it-4bit"))
        XCTAssertTrue(visibleModelIds.contains("mlx-community/Qwen3.6-27B-4bit"))
        XCTAssertTrue(visibleModelIds.contains("mlx-community/Qwen3.6-35B-A3B-4bit"))
    }

    func testPerModeSelectionPersistsIndependentDefaultsForEachModality() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let store = ModelSelectionStore(userDefaults: defaults)
        let imageModelId = "black-forest-labs/FLUX.2-klein-4B"
        let speechModelId = "kugelaudio/kugelaudio-0-open"
        let musicModelId = "ACE-Step/acestep-v15-turbo-continuous"

        store.setSelectedModelId(AIModel.gemma4.modelId, for: .vision)
        store.setSelectedModelId(imageModelId, for: .image)
        store.setSelectedModelId(speechModelId, for: .audio)
        store.setSelectedModelId(musicModelId, for: .music)

        XCTAssertEqual(store.selectedProfile(for: .vision, hardwareMemoryGB: 16.0, runtimeManifest: testRuntimeManifest)?.modelId, AIModel.gemma4.modelId)
        XCTAssertEqual(store.selectedProfile(for: .image, hardwareMemoryGB: 16.0, runtimeManifest: testRuntimeManifest)?.modelId, imageModelId)
        XCTAssertEqual(store.selectedProfile(for: .audio, hardwareMemoryGB: 16.0, runtimeManifest: testRuntimeManifest)?.modelId, speechModelId)
        XCTAssertEqual(store.selectedProfile(for: .music, hardwareMemoryGB: 16.0, runtimeManifest: testRuntimeManifest)?.modelId, musicModelId)
    }

    func testModelSettingsSorterOrdersDefaultsRecommendationsReadinessFitAndSize() {
        let selected = makeDownloadableModel(id: "selected", size: 8, memory: 10)
        let recommended = makeDownloadableModel(id: "recommended", size: 7, memory: 3)
        let readySmall = makeDownloadableModel(id: "ready-small", size: 2, memory: 3)
        let missing = makeDownloadableModel(id: "missing", size: 1, memory: 3)
        let incompatible = makeDownloadableModel(
            id: "incompatible",
            size: 1,
            memory: 3,
            runtime: ModelRuntimeRequirement(minVersion: "9.0.0", compatibilityApi: 1)
        )
        let states: [String: ModelDownloadManager.DownloadState] = [
            selected.id: .notDownloaded,
            recommended.id: .downloaded,
            readySmall.id: .downloaded,
            missing.id: .notDownloaded,
            incompatible.id: .downloaded
        ]

        let sorted = ModelSettingsModelSorter.sorted(
            models: [missing, incompatible, readySmall, selected, recommended],
            selectedModelId: selected.modelId,
            recommendedModelId: recommended.modelId,
            state: { states[$0.id] ?? .notDownloaded },
            hardwareMemoryGB: 8,
            runtimeManifest: RuntimeManifest(
                runtimeVersion: "0.1.0",
                compatibilityApi: 1,
                supportedBackends: RuntimeBackend.allCases
            )
        )

        XCTAssertEqual(
            sorted.map(\.id),
            ["selected", "recommended", "ready-small", "missing", "incompatible"]
        )
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

    func testPersistedParameterValuesAreValidatedAndClampedBeforeExecution() throws {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let image = ModelCapabilityProfile.embeddedProfile(modelId: "black-forest-labs/FLUX.2-klein-4B")!
        let encoded = try JSONEncoder().encode([
            image.modelId: [
                "width": "99999",
                "height": "not-a-number"
            ]
        ])
        defaults.set(encoded, forKey: ModelParameterStore.storageKey)

        let store = ModelParameterStore(userDefaults: defaults)
        let values = store.values(for: image)
        let parameters = store.executionParameters(for: image)

        XCTAssertEqual(values["width"], image.parameterDefinition(key: "width")?.clampedString(99999))
        XCTAssertEqual(values["height"], image.parameterDefinition(key: "height")?.defaultValue)
        XCTAssertEqual(parameters["width"] as? Int, Int(Double(values["width"] ?? "") ?? 0))
    }

    func testResetOnlyClearsCurrentModelParameters() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let store = ModelParameterStore(userDefaults: defaults)
        let qwen = ModelCapabilityProfile.embeddedProfile(modelId: AIModel.qwen35.modelId)!
        let gemma = ModelCapabilityProfile.embeddedProfile(modelId: AIModel.gemma4.modelId)!

        store.setValue("0.2", for: "temperature", modelId: qwen.modelId)
        store.setValue("0.4", for: "temperature", modelId: gemma.modelId)
        store.reset(profile: qwen)

        XCTAssertEqual(store.values(for: qwen)["temperature"], qwen.parameterDefinition(key: "temperature")?.defaultValue)
        XCTAssertEqual(store.values(for: gemma)["temperature"], "0.4")
    }

    func testExecutionParametersAreScopedToProfile() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let store = ModelParameterStore(userDefaults: defaults)
        let image = ModelCapabilityProfile.embeddedProfile(modelId: "black-forest-labs/FLUX.2-klein-4B")!
        let speech = ModelCapabilityProfile.embeddedProfile(modelId: "kugelaudio/kugelaudio-0-open")!
        let music = ModelCapabilityProfile.embeddedProfile(modelId: "ACE-Step/acestep-v15-turbo-continuous")!

        store.setValue("1536", for: "width", modelId: image.modelId)
        store.setValue("4.5", for: "cfg_scale", modelId: speech.modelId)
        store.setValue("45", for: "duration", modelId: music.modelId)

        let imageParameters = store.executionParameters(for: image)
        let speechParameters = store.executionParameters(for: speech)
        let musicParameters = store.executionParameters(for: music)

        XCTAssertEqual(imageParameters["width"] as? Int, 1536)
        XCTAssertNil(imageParameters["cfg_scale"])
        XCTAssertNil(imageParameters["duration"])

        XCTAssertEqual(speechParameters["cfg_scale"] as? Double, 4.5)
        XCTAssertNil(speechParameters["width"])
        XCTAssertNil(speechParameters["duration"])

        XCTAssertEqual(musicParameters["duration"] as? Int, 45)
        XCTAssertNil(musicParameters["width"])
        XCTAssertNil(musicParameters["cfg_scale"])
    }

    func testCatalogDecodingPreservesSourceRuntimeAndRanking() throws {
        let data = try makeCatalogJSON(
            modelId: "org/example-vlm",
            memoryGB: 4.0,
            minRuntimeVersion: "0.2.0"
        )

        let catalog = try ModelCatalogService.decodeCatalog(data: data, appVersion: "1.0.0")
        let profile = try XCTUnwrap(catalog.profiles.first)

        XCTAssertEqual(profile.modelId, "org/example-vlm")
        XCTAssertEqual(profile.backend, .vlm)
        XCTAssertEqual(profile.source.type, .huggingFaceSnapshot)
        XCTAssertEqual(profile.source.revision, "main")
        XCTAssertEqual(profile.runtime.minVersion, "0.2.0")
        XCTAssertEqual(profile.ranking.quality, 90)
    }

    func testCatalogRejectsChecksumMismatch() throws {
        let data = try makeCatalogJSON(modelId: "org/example-vlm")

        XCTAssertThrowsError(
            try ModelCatalogService.decodeCatalog(data: data, expectedSHA256: String(repeating: "0", count: 64))
        ) { error in
            XCTAssertEqual(error as? ModelCatalogError, .checksumMismatch)
        }
    }

    func testCatalogRejectsIncompatibleAppVersion() throws {
        let data = try makeCatalogJSON(modelId: "org/example-vlm", minAppVersion: "9.0.0")

        XCTAssertThrowsError(
            try ModelCatalogService.decodeCatalog(data: data, appVersion: "1.0.0")
        ) { error in
            XCTAssertEqual(error as? ModelCatalogError, .incompatibleAppVersion("9.0.0"))
        }
    }

    func testCatalogServiceFallsBackWhenNoCacheOrBundleIsAvailable() {
        let service = ModelCatalogService(loadCachedCatalog: false, loadBundledCatalog: false)

        XCTAssertEqual(service.profiles.count, ModelCapabilityProfile.embedded.count)
        XCTAssertNotNil(service.profile(legacyModel: .mini))
    }

    func testRuntimeCompatibilityUsesManifestVersionAndBackend() throws {
        let data = try makeCatalogJSON(
            modelId: "org/future-vlm",
            memoryGB: 4.0,
            minRuntimeVersion: "0.2.0"
        )
        let profile = try XCTUnwrap(ModelCatalogService.decodeCatalog(data: data, appVersion: "1.0.0").profiles.first)
        let oldRuntime = RuntimeManifest(
            runtimeVersion: "0.1.0",
            compatibilityApi: 1,
            supportedBackends: [.vlm]
        )
        let newRuntime = RuntimeManifest(
            runtimeVersion: "0.2.0",
            compatibilityApi: 1,
            supportedBackends: [.vlm]
        )
        let wrongBackendRuntime = RuntimeManifest(
            runtimeVersion: "0.2.0",
            compatibilityApi: 1,
            supportedBackends: [.image]
        )

        XCTAssertFalse(oldRuntime.supports(profile: profile))
        XCTAssertTrue(newRuntime.supports(profile: profile))
        XCTAssertFalse(wrongBackendRuntime.supports(profile: profile))
    }

    func testVersionComparatorOrdersPrereleasesBeforeFinalReleases() {
        XCTAssertEqual(VersionComparator.compare("0.2.0-beta", "0.2.0"), .orderedAscending)
        XCTAssertEqual(VersionComparator.compare("0.2.0-beta.2", "0.2.0-beta.10"), .orderedAscending)
        XCTAssertEqual(VersionComparator.compare("0.2.0+build.1", "0.2.0+build.2"), .orderedSame)
        XCTAssertEqual(VersionComparator.compare("0.2.1", "0.2.0-rc.1"), .orderedDescending)
    }

    func testCatalogValidationRejectsUnsupportedSchemaEmptyCatalogAndDuplicateIds() throws {
        let unsupportedSchema = Data("""
        {
          "schemaVersion": 2,
          "catalogVersion": "test",
          "models": []
        }
        """.utf8)
        XCTAssertThrowsError(try ModelCatalogService.decodeCatalog(data: unsupportedSchema, appVersion: "1.0.0")) { error in
            XCTAssertEqual(error as? ModelCatalogError, .unsupportedSchema(2))
        }

        let emptyCatalog = Data("""
        {
          "schemaVersion": 1,
          "catalogVersion": "test",
          "models": []
        }
        """.utf8)
        XCTAssertThrowsError(try ModelCatalogService.decodeCatalog(data: emptyCatalog, appVersion: "1.0.0")) { error in
            XCTAssertEqual(error as? ModelCatalogError, .emptyCatalog)
        }

        let duplicateCatalog = try makeCatalogJSON(modelId: "org/duplicate-vlm", duplicateModel: true)
        XCTAssertThrowsError(try ModelCatalogService.decodeCatalog(data: duplicateCatalog, appVersion: "1.0.0")) { error in
            XCTAssertEqual(error as? ModelCatalogError, .duplicateModelId("org/duplicate-vlm"))
        }

        let duplicateModelIdCatalog = try makeCatalogJSON(
            modelId: "org/shared-vlm",
            duplicateModelIdWithDifferentProfileId: true
        )
        XCTAssertThrowsError(try ModelCatalogService.decodeCatalog(data: duplicateModelIdCatalog, appVersion: "1.0.0")) { error in
            XCTAssertEqual(error as? ModelCatalogError, .duplicateModelId("org/shared-vlm"))
        }
    }

    func testCatalogValidationRejectsInvalidParameterDefinitions() throws {
        let duplicateParameters = try makeCatalogJSON(
            modelId: "org/invalid-params",
            parameters: """
            [
                {"key": "width", "label": "Width", "type": "integer", "defaultValue": "512", "range": {"min": 256, "max": 1024}, "step": 64},
                {"key": "width", "label": "Duplicate", "type": "integer", "defaultValue": "512", "range": {"min": 256, "max": 1024}, "step": 64}
            ]
            """
        )
        XCTAssertThrowsError(try ModelCatalogService.decodeCatalog(data: duplicateParameters, appVersion: "1.0.0")) { error in
            guard case .invalidParameter(let message) = error as? ModelCatalogError else {
                XCTFail("Expected invalid parameter error, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("duplicate parameter key width"))
        }

        let invalidDefault = try makeCatalogJSON(
            modelId: "org/invalid-default",
            parameters: """
            [
                {"key": "duration", "label": "Duration", "type": "integer", "defaultValue": "4", "range": {"min": 5, "max": 60}, "step": 1}
            ]
            """
        )
        XCTAssertThrowsError(try ModelCatalogService.decodeCatalog(data: invalidDefault, appVersion: "1.0.0")) { error in
            guard case .invalidParameter(let message) = error as? ModelCatalogError else {
                XCTFail("Expected invalid parameter error, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("default is outside its range"))
        }
    }

    func testCatalogErrorsExposeReadableDescriptions() {
        XCTAssertEqual(
            ModelCatalogError.unsupportedSchema(7).errorDescription,
            "Unsupported model catalog schema 7"
        )
        XCTAssertEqual(
            ModelCatalogError.incompatibleAppVersion("2.0.0").errorDescription,
            "Model catalog requires MLXtra 2.0.0 or newer"
        )
        XCTAssertEqual(
            ModelCatalogError.checksumMismatch.errorDescription,
            "Model catalog checksum did not match"
        )
        XCTAssertEqual(
            ModelCatalogError.emptyCatalog.errorDescription,
            "Model catalog does not contain any models"
        )
        XCTAssertEqual(
            ModelCatalogError.duplicateModelId("org/model").errorDescription,
            "Model catalog contains duplicate model id org/model"
        )
    }

    func testModelModalityDecodesAliasesEncodesCanonicalValuesAndRejectsUnknowns() throws {
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()

        XCTAssertEqual(try decoder.decode(ModelModality.self, from: Data(#""chat""#.utf8)), .vision)
        XCTAssertEqual(try decoder.decode(ModelModality.self, from: Data(#"" speech ""#.utf8)), .audio)
        XCTAssertEqual(try decoder.decode(ModelModality.self, from: Data(#""image""#.utf8)), .image)
        XCTAssertEqual(try decoder.decode(ModelModality.self, from: Data(#""music""#.utf8)), .music)
        XCTAssertEqual(String(data: try encoder.encode(ModelModality.vision), encoding: .utf8), #""vision""#)
        XCTAssertEqual(String(data: try encoder.encode(ModelModality.music), encoding: .utf8), #""music""#)

        XCTAssertThrowsError(try decoder.decode(ModelModality.self, from: Data(#""text""#.utf8)))
    }

    func testParameterDefinitionTypingClampingAndCodableDefaults() throws {
        let decimal = ModelParameterDefinition(
            key: "temperature",
            label: "Temperature",
            type: .decimal,
            defaultValue: "0.7",
            range: 0...2,
            step: 0.1
        )
        let integer = ModelParameterDefinition(
            key: "steps",
            label: "Steps",
            type: .integer,
            defaultValue: "4",
            range: 1...12
        )
        let boolean = ModelParameterDefinition(key: "enabled", label: "Enabled", type: .boolean, defaultValue: "false")
        let option = ModelParameterDefinition(
            key: "voice",
            label: "Voice",
            type: .option,
            defaultValue: "alloy",
            options: ["alloy", "verse"]
        )
        let text = ModelParameterDefinition(key: "prompt", label: "Prompt", type: .text, defaultValue: "")

        XCTAssertEqual(decimal.typedValue(from: "1.25") as? Double, 1.25)
        XCTAssertEqual(integer.typedValue(from: "4") as? Int, 4)
        XCTAssertNil(integer.typedValue(from: "4.8"))
        XCTAssertEqual(boolean.typedValue(from: " YES ") as? Bool, true)
        XCTAssertEqual(boolean.typedValue(from: "no") as? Bool, false)
        XCTAssertNil(boolean.typedValue(from: "maybe"))
        XCTAssertEqual(option.typedValue(from: "verse") as? String, "verse")
        XCTAssertEqual(text.typedValue(from: "hello") as? String, "hello")

        XCTAssertEqual(decimal.clampedString(2.5), "2")
        XCTAssertEqual(decimal.clampedString(1.25), "1.25")
        XCTAssertEqual(integer.clampedString(12.9), "12")
        XCTAssertEqual(boolean.clampedString(1), "false")

        let decoded = try JSONDecoder().decode(ModelParameterDefinition.self, from: Data("""
        {
          "key": "duration",
          "label": "Duration",
          "type": "integer",
          "defaultValue": "30",
          "range": { "min": 5, "max": 60 }
        }
        """.utf8))
        XCTAssertEqual(decoded.step, 1)
        XCTAssertEqual(decoded.options, [])
        XCTAssertFalse(decoded.isAdvanced)
        XCTAssertEqual(decoded.range, 5...60)

        let encoded = try JSONEncoder().encode(decimal)
        let roundTripped = try JSONDecoder().decode(ModelParameterDefinition.self, from: encoded)
        XCTAssertEqual(roundTripped, decimal)
    }

    func testModelSourceDefaultsAndRuntimeRequirements() {
        let aceSource = ModelSource.defaultSource(modelId: "ACE-Step/acestep-v15-turbo-continuous")
        XCTAssertEqual(aceSource.type, .componentBundle)
        XCTAssertEqual(aceSource.downloadRepository, "ACE-Step/acestep-v15-turbo-continuous")
        XCTAssertTrue(aceSource.usesComponentBundle)
        XCTAssertEqual(aceSource.components, ["acestep-v15-turbo", "vae", "Qwen3-Embedding-0.6B", "acestep-5Hz-lm-1.7B"])

        let snapshotSource = ModelSource.defaultSource(modelId: "org/model")
        XCTAssertEqual(snapshotSource.type, .huggingFaceSnapshot)
        XCTAssertEqual(snapshotSource.downloadRepository, "org/model")
        XCTAssertFalse(snapshotSource.usesComponentBundle)
        XCTAssertEqual(snapshotSource.revision, "main")

        let requirement = ModelRuntimeRequirement(minVersion: "0.2.0", compatibilityApi: 3)
        XCTAssertFalse(requirement.isSatisfied(by: nil))
        XCTAssertFalse(requirement.isSatisfied(by: RuntimeManifest(runtimeVersion: "0.1.9", compatibilityApi: 3, supportedBackends: [.vlm])))
        XCTAssertFalse(requirement.isSatisfied(by: RuntimeManifest(runtimeVersion: "0.2.0", compatibilityApi: 2, supportedBackends: [.vlm])))
        XCTAssertTrue(requirement.isSatisfied(by: RuntimeManifest(runtimeVersion: "0.2.0", compatibilityApi: 3, supportedBackends: [.vlm])))
    }

    private var defaultsSuiteName: String {
        "MLXtraTests.ModelCapabilityProfileTests"
    }

    private var testRuntimeManifest: RuntimeManifest {
        RuntimeManifest(
            runtimeVersion: "9.0.0",
            compatibilityApi: 1,
            supportedBackends: RuntimeBackend.allCases
        )
    }

    private func makeDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: defaultsSuiteName)!
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        return defaults
    }

    private func makeDownloadableModel(
        id: String,
        size: Double,
        memory: Double,
        runtime: ModelRuntimeRequirement = ModelRuntimeRequirement()
    ) -> DownloadableModel {
        DownloadableModel(
            id: id,
            name: id,
            subtitle: "Test model",
            modelId: "org/\(id)",
            modality: .vision,
            backend: .vlm,
            downloadSizeGB: size,
            estimatedMemoryGB: memory,
            source: ModelSource(type: .huggingFaceSnapshot, repo: "org/\(id)", revision: "main"),
            runtime: runtime
        )
    }

    private func makeCatalogJSON(
        modelId: String,
        memoryGB: Double = 4.0,
        minRuntimeVersion: String = "0.1.0",
        minAppVersion: String = "0.1.0",
        duplicateModel: Bool = false,
        duplicateModelIdWithDifferentProfileId: Bool = false,
        parameters: String = "[]"
    ) throws -> Data {
        let model = """
            {
              "id": "\(modelId)",
              "name": "Example VLM",
              "subtitle": "Test model",
              "modelId": "\(modelId)",
              "modality": "vision",
              "backend": "vlm",
              "icon": "eye",
              "capabilities": ["chat", "vision"],
              "maxContextWindow": 4096,
              "defaultMaxTokens": 512,
              "downloadSizeGB": 1.0,
              "estimatedMemoryGB": \(memoryGB),
              "source": {
                "type": "hugging_face_snapshot",
                "repo": "\(modelId)",
                "revision": "main",
                "components": []
              },
              "runtime": {
                "minVersion": "\(minRuntimeVersion)",
                "compatibilityApi": 1
              },
              "ranking": {
                "quality": 90,
                "speed": 80
              },
              "parameters": \(parameters),
              "presets": []
            }
        """
        let alternateProfileModel = model.replacingOccurrences(
            of: #""id": "\#(modelId)""#,
            with: #""id": "org/alternate-profile""#
        )
        let models: String
        if duplicateModel {
            models = "\(model),\n\(model)"
        } else if duplicateModelIdWithDifferentProfileId {
            models = "\(model),\n\(alternateProfileModel)"
        } else {
            models = model
        }

        return Data("""
        {
          "schemaVersion": 1,
          "catalogVersion": "test",
          "minAppVersion": "\(minAppVersion)",
          "models": [
        \(models)
          ]
        }
        """.utf8)
    }
}
