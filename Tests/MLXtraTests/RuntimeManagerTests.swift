import XCTest
import Combine
@testable import MLXtra

final class RuntimeManagerTests: XCTestCase {


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
            RuntimeError.runtimeComponentNotFound("ACE-Step Python executable", "/path/to/acestep-python").localizedDescription,
            "ACE-Step Python executable not found at /path/to/acestep-python. Rebuild the bundled runtime with ./Scripts/build-runtime-bundle.sh"
        )
        XCTAssertEqual(
            RuntimeError.pythonValidationFailed("ACE-Step download runtime", "No module named 'acestep'").localizedDescription,
            "ACE-Step download runtime is incomplete or broken. Rebuild the bundled runtime with ./Scripts/build-runtime-bundle.sh. No module named 'acestep'"
        )
        XCTAssertEqual(
            RuntimeError.initializationFailed("test failure").localizedDescription,
            "Failed to initialize runtime: test failure"
        )
    }

    func testRuntimeErrorBridgesLocalizedDescriptionThroughError() {
        let error: Error = RuntimeError.runtimeComponentNotFound("ACE-Step download helper", "/path/to/helper")

        XCTAssertEqual(
            error.localizedDescription,
            "ACE-Step download helper not found at /path/to/helper. Rebuild the bundled runtime with ./Scripts/build-runtime-bundle.sh"
        )
    }

    func testFileSHA256MatchesDataSHA256() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let bytes = (0..<(2 * 1024 * 1024 + 37)).map { UInt8($0 % 251) }
        let data = Data(bytes)
        let fileURL = directory.appendingPathComponent("archive.zip")
        try data.write(to: fileURL)

        XCTAssertEqual(
            try SHA256Checksum.hexDigest(for: fileURL),
            SHA256Checksum.hexDigest(for: data)
        )
    }


    @MainActor
    func testEstimatedModelSizeUsesCatalog() throws {
        let runtimeManager = RuntimeManager()
        let chatProfile = try XCTUnwrap(ModelCapabilityProfile.embeddedProfile(modelId: "mlx-community/Qwen3.5-9B-MLX-4bit"))
        let speechProfile = try XCTUnwrap(ModelCapabilityProfile.embeddedProfile(modelId: "mlx-community/Kokoro-82M-4bit"))

        XCTAssertEqual(runtimeManager.estimatedModelSize(modelId: chatProfile.modelId), chatProfile.totalDownloadSizeGB)
        XCTAssertEqual(runtimeManager.estimatedModelSize(modelId: speechProfile.modelId), speechProfile.totalDownloadSizeGB)
        XCTAssertEqual(runtimeManager.estimatedModelSize(modelId: "unknown/model"), 5.0)
    }


    func testModelCachePathConstruction() {
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


    func testPythonExecutablePathStructure() {
        let path = "/some/path/venv/bin/python"
        XCTAssertTrue(path.hasSuffix("/venv/bin/python"))
    }

    func testAcestepPythonExecutablePathStructure() {
        let path = "/some/path/acestep-venv/bin/python"
        XCTAssertTrue(path.hasSuffix("/acestep-venv/bin/python"))
    }


    func testSnapshotValidationFindsWeightsAtSnapshotRoot() throws {
        let snapshotPath = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: snapshotPath) }

        try Data("{}".utf8).write(to: snapshotPath.appendingPathComponent("config.json"))
        XCTAssertFalse(RuntimeManager.snapshotContainsModelFiles(snapshotPath))

        try Data([1]).write(to: snapshotPath.appendingPathComponent("model.safetensors"))
        XCTAssertTrue(RuntimeManager.snapshotContainsModelFiles(snapshotPath))
    }

    func testSnapshotValidationFindsNestedWeights() throws {
        let snapshotPath = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: snapshotPath) }

        try Data("{}".utf8).write(to: snapshotPath.appendingPathComponent("model_index.json"))

        let transformerPath = snapshotPath.appendingPathComponent("transformer")
        try FileManager.default.createDirectory(at: transformerPath, withIntermediateDirectories: true)
        try Data([1]).write(to: transformerPath.appendingPathComponent("diffusion_pytorch_model.safetensors"))

        XCTAssertTrue(RuntimeManager.snapshotContainsModelFiles(snapshotPath))
    }

    func testSnapshotValidationFindsMetadataInSubdirectories() throws {
        let snapshotPath = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: snapshotPath) }

        
        let transformerPath = snapshotPath.appendingPathComponent("transformer")
        try FileManager.default.createDirectory(at: transformerPath, withIntermediateDirectories: true)
        
        try Data("{}".utf8).write(to: transformerPath.appendingPathComponent("config.json"))
        
        try Data([1]).write(to: transformerPath.appendingPathComponent("diffusion_pytorch_model.safetensors"))

        XCTAssertTrue(RuntimeManager.snapshotContainsModelFiles(snapshotPath))
    }

    func testSnapshotValidationFindsSymlinkedWeights() throws {
        let rootPath = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootPath) }

        let blobsPath = rootPath.appendingPathComponent("blobs")
        let snapshotPath = rootPath.appendingPathComponent("snapshots/revision")
        try FileManager.default.createDirectory(at: blobsPath, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: snapshotPath, withIntermediateDirectories: true)

        let blobPath = blobsPath.appendingPathComponent("weight-blob")
        try Data([1]).write(to: blobPath)
        try Data("{}".utf8).write(to: snapshotPath.appendingPathComponent("config.json"))

        try FileManager.default.createSymbolicLink(
            atPath: snapshotPath.appendingPathComponent("model.safetensors").path,
            withDestinationPath: "../../blobs/weight-blob"
        )

        XCTAssertTrue(RuntimeManager.snapshotContainsModelFiles(snapshotPath))
    }

    func testSnapshotValidationRejectsZeroByteWeights() throws {
        let snapshotPath = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: snapshotPath) }

        try Data("{}".utf8).write(to: snapshotPath.appendingPathComponent("config.json"))
        FileManager.default.createFile(
            atPath: snapshotPath.appendingPathComponent("model.safetensors").path,
            contents: Data()
        )

        XCTAssertFalse(RuntimeManager.snapshotContainsModelFiles(snapshotPath))
    }

    func testSnapshotValidationRejectsIndexWithoutDeclaredWeights() throws {
        let snapshotPath = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: snapshotPath) }

        try Data("{}".utf8).write(to: snapshotPath.appendingPathComponent("config.json"))
        try Data("""
        {
          "metadata": {},
          "weight_map": {
            "layer.0": "model-00001-of-00002.safetensors",
            "layer.1": "model-00002-of-00002.safetensors"
          }
        }
        """.utf8).write(to: snapshotPath.appendingPathComponent("model.safetensors.index.json"))
        try Data([1]).write(to: snapshotPath.appendingPathComponent("model-00001-of-00002.safetensors"))

        XCTAssertFalse(RuntimeManager.snapshotContainsModelFiles(snapshotPath))
    }

    func testSnapshotValidationAcceptsCompleteDeclaredWeightIndex() throws {
        let snapshotPath = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: snapshotPath) }

        try Data("{}".utf8).write(to: snapshotPath.appendingPathComponent("config.json"))
        try Data("""
        {
          "metadata": {},
          "weight_map": {
            "layer.0": "model-00001-of-00002.safetensors",
            "layer.1": "model-00002-of-00002.safetensors"
          }
        }
        """.utf8).write(to: snapshotPath.appendingPathComponent("model.safetensors.index.json"))
        try Data([1]).write(to: snapshotPath.appendingPathComponent("model-00001-of-00002.safetensors"))
        try Data([1]).write(to: snapshotPath.appendingPathComponent("model-00002-of-00002.safetensors"))

        XCTAssertTrue(RuntimeManager.snapshotContainsModelFiles(snapshotPath))
    }

    func testSnapshotValidationRejectsWeightsWithoutMetadata() throws {
        let snapshotPath = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: snapshotPath) }

        try Data([1]).write(to: snapshotPath.appendingPathComponent("model.safetensors"))

        XCTAssertFalse(RuntimeManager.snapshotContainsModelFiles(snapshotPath))
    }

    func testAceStepStorageStatusDistinguishesMissingIncompleteAndDownloaded() throws {
        let checkpointsPath = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: checkpointsPath) }
        let modelId = "ACE-Step/acestep-v15-turbo-continuous"

        XCTAssertEqual(
            RuntimeManager.modelStorageStatus(modelId: modelId, checkpointsPath: checkpointsPath),
            .missing
        )

        let partialComponent = checkpointsPath.appendingPathComponent("acestep-v15-turbo")
        try FileManager.default.createDirectory(at: partialComponent, withIntermediateDirectories: true)
        try Data([1]).write(to: partialComponent.appendingPathComponent("model.safetensors"))

        guard case .incomplete(let message) = RuntimeManager.modelStorageStatus(
            modelId: modelId,
            checkpointsPath: checkpointsPath
        ) else {
            XCTFail("Expected incomplete ACE-Step checkpoint status")
            return
        }
        XCTAssertTrue(message.contains("Model components are incomplete"))

        for component in ["vae", "Qwen3-Embedding-0.6B", "acestep-5Hz-lm-1.7B"] {
            let componentPath = checkpointsPath.appendingPathComponent(component)
            try FileManager.default.createDirectory(at: componentPath, withIntermediateDirectories: true)
            try Data([1]).write(to: componentPath.appendingPathComponent("model.safetensors"))
        }

        XCTAssertEqual(
            RuntimeManager.modelStorageStatus(modelId: modelId, checkpointsPath: checkpointsPath),
            .downloaded
        )
    }

    func testAceStepStorageStatusMapsRuntimeAliasesToCatalogBundle() throws {
        let checkpointsPath = try makeTemporaryDirectory()
        let cacheRoot = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: checkpointsPath)
            try? FileManager.default.removeItem(at: cacheRoot)
        }

        for component in ["acestep-v15-turbo", "vae", "Qwen3-Embedding-0.6B", "acestep-5Hz-lm-1.7B"] {
            let componentPath = checkpointsPath.appendingPathComponent(component)
            try FileManager.default.createDirectory(at: componentPath, withIntermediateDirectories: true)
            try Data([1]).write(to: componentPath.appendingPathComponent("model.safetensors"))
        }

        for alias in ["ACE-Step/acestep-v15-turbo-shift3", "acestep-v15-turbo-rl"] {
            XCTAssertEqual(
                RuntimeManager.modelStorageStatus(
                    modelId: alias,
                    checkpointsPath: checkpointsPath,
                    huggingFaceCacheRoot: cacheRoot
                ),
                .downloaded
            )
        }

        XCTAssertEqual(
            RuntimeManager.modelStorageStatus(
                modelId: "ACE-Step/acestep-v15-base",
                checkpointsPath: checkpointsPath,
                huggingFaceCacheRoot: cacheRoot
            ),
            .missing
        )
    }

    func testModelStorageStatusUsesProvidedHuggingFaceCacheRoot() throws {
        let cacheRoot = try makeTemporaryDirectory()
        let defaultCheckpoints = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: cacheRoot)
            try? FileManager.default.removeItem(at: defaultCheckpoints)
        }

        let modelId = "org/custom-cache-model"
        let modelCachePath = RuntimeManager.modelCachePath(
            modelId: modelId,
            huggingFaceCacheRoot: cacheRoot
        )
        let snapshotPath = modelCachePath
            .appendingPathComponent("snapshots")
            .appendingPathComponent("revision")
        try FileManager.default.createDirectory(
            at: snapshotPath,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: modelCachePath.appendingPathComponent("refs"),
            withIntermediateDirectories: true
        )
        try Data("revision".utf8).write(to: modelCachePath.appendingPathComponent("refs/main"))
        try Data("{}".utf8).write(to: snapshotPath.appendingPathComponent("config.json"))
        try Data([1]).write(to: snapshotPath.appendingPathComponent("model.safetensors"))

        XCTAssertEqual(
            RuntimeManager.modelStorageStatus(
                modelId: modelId,
                checkpointsPath: defaultCheckpoints,
                huggingFaceCacheRoot: cacheRoot
            ),
            .downloaded
        )
    }

    func testModelStorageStatusHonorsModelRevisionRefOverOtherSnapshots() throws {
        let cacheRoot = try makeTemporaryDirectory()
        let defaultCheckpoints = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: cacheRoot)
            try? FileManager.default.removeItem(at: defaultCheckpoints)
        }

        let modelId = "org/custom-revision-model"
        let model = DownloadableModel(
            id: modelId,
            name: "Custom Revision",
            subtitle: "Test model",
            modelId: modelId,
            modality: .vision,
            downloadSizeGB: 1.0,
            source: ModelSource(type: .huggingFaceSnapshot, repo: modelId, revision: "custom")
        )
        let modelCachePath = RuntimeManager.modelCachePath(
            modelId: modelId,
            huggingFaceCacheRoot: cacheRoot
        )
        let refsPath = modelCachePath.appendingPathComponent("refs")
        let expectedSnapshotPath = modelCachePath
            .appendingPathComponent("snapshots")
            .appendingPathComponent("custom-revision")
        let otherSnapshotPath = modelCachePath
            .appendingPathComponent("snapshots")
            .appendingPathComponent("other-revision")

        try FileManager.default.createDirectory(at: refsPath, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: expectedSnapshotPath, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: otherSnapshotPath, withIntermediateDirectories: true)
        try Data("custom-revision".utf8).write(to: refsPath.appendingPathComponent("custom"))
        try Data("in-progress".utf8).write(
            to: expectedSnapshotPath.appendingPathComponent(NativeSnapshotCompletionManifest.inProgressFilename)
        )

        try Data("{}".utf8).write(to: otherSnapshotPath.appendingPathComponent("config.json"))
        try Data([1]).write(to: otherSnapshotPath.appendingPathComponent("model.safetensors"))
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2_000_000_000)],
            ofItemAtPath: otherSnapshotPath.path
        )

        guard case .incomplete(let message) = RuntimeManager.modelStorageStatus(
            model: model,
            checkpointsPath: defaultCheckpoints,
            huggingFaceCacheRoot: cacheRoot
        ) else {
            return XCTFail("Expected the configured revision snapshot to be incomplete")
        }
        XCTAssertTrue(message.contains("Native model download is still incomplete"))
    }

    func testModelStorageStatusForEmbeddedHuggingFaceModelDoesNotRecurse() throws {
        let cacheRoot = try makeTemporaryDirectory()
        let checkpointsPath = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: cacheRoot)
            try? FileManager.default.removeItem(at: checkpointsPath)
        }

        let model = try XCTUnwrap(
            DownloadableModel.embeddedModel(modelId: "mlx-community/Qwen3.5-2B-MLX-4bit")
        )

        XCTAssertEqual(
            RuntimeManager.modelStorageStatus(
                model: model,
                checkpointsPath: checkpointsPath,
                huggingFaceCacheRoot: cacheRoot
            ),
            .missing
        )
    }

    func testModelStorageStatusRequiresAccelerationSnapshot() throws {
        let cacheRoot = try makeTemporaryDirectory()
        let checkpointsPath = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: cacheRoot)
            try? FileManager.default.removeItem(at: checkpointsPath)
        }

        let model = DownloadableModel(
            id: "org/base-model",
            name: "Base Model",
            subtitle: "Test model",
            modelId: "org/base-model",
            modality: .vision,
            downloadSizeGB: 1.0,
            source: ModelSource(type: .huggingFaceSnapshot, repo: "org/base-model", revision: "main"),
            acceleration: ModelAcceleration(modelId: "org/base-drafter", downloadSizeGB: 0.25)
        )
        let storageURLs = ModelDownloadStorage.storageURLs(
            for: model,
            checkpointsPath: checkpointsPath,
            huggingFaceCacheRoot: cacheRoot
        )

        XCTAssertEqual(storageURLs.count, 2)
        XCTAssertTrue(storageURLs[0].path.contains("models--org--base-model"))
        XCTAssertTrue(storageURLs[1].path.contains("models--org--base-drafter"))

        let baseSnapshot = try makeNativeSnapshotDirectory(modelId: "org/base-model", cacheRoot: cacheRoot)
        try Data("{}".utf8).write(to: baseSnapshot.appendingPathComponent("config.json"))
        try Data([1]).write(to: baseSnapshot.appendingPathComponent("model.safetensors"))

        guard case .incomplete(let message) = RuntimeManager.modelStorageStatus(
            model: model,
            checkpointsPath: checkpointsPath,
            huggingFaceCacheRoot: cacheRoot
        ) else {
            return XCTFail("Expected missing acceleration files to be repairable incomplete")
        }
        XCTAssertTrue(message.contains("Model update required"))
        XCTAssertTrue(message.contains("acceleration files are missing"))

        let drafterSnapshot = try makeNativeSnapshotDirectory(modelId: "org/base-drafter", cacheRoot: cacheRoot)
        try Data("{}".utf8).write(to: drafterSnapshot.appendingPathComponent("config.json"))
        try Data([1]).write(to: drafterSnapshot.appendingPathComponent("model.safetensors"))

        XCTAssertEqual(
            RuntimeManager.modelStorageStatus(
                model: model,
                checkpointsPath: checkpointsPath,
                huggingFaceCacheRoot: cacheRoot
            ),
            .downloaded
        )
        XCTAssertEqual(
            RuntimeManager.downloadedSnapshotPath(
                modelId: "org/base-drafter",
                huggingFaceCacheRoot: cacheRoot
            )?.path,
            drafterSnapshot.path
        )
    }

    func testComponentBundleStorageUsesConfiguredSubdirectory() throws {
        let checkpointsPath = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: checkpointsPath) }
        let model = try XCTUnwrap(
            DownloadableModel.embeddedModel(modelId: "google/magenta-realtime-2/mrt2_small")
        )

        let storageURLs = ModelDownloadStorage.storageURLs(
            for: model,
            checkpointsPath: checkpointsPath
        )

        XCTAssertEqual(
            storageURLs,
            [
                checkpointsPath.appendingPathComponent("magenta-realtime-2/mrt2_small/models/mrt2_small"),
                checkpointsPath.appendingPathComponent("magenta-realtime-2/mrt2_small/resources/musiccoca"),
            ]
        )
    }

    func testModelStorageStatusForEmbeddedHuggingFaceModelIdDoesNotRecurse() throws {
        let cacheRoot = try makeTemporaryDirectory()
        let checkpointsPath = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: cacheRoot)
            try? FileManager.default.removeItem(at: checkpointsPath)
        }

        XCTAssertEqual(
            RuntimeManager.modelStorageStatus(
                modelId: "mlx-community/Qwen3.5-2B-MLX-4bit",
                checkpointsPath: checkpointsPath,
                huggingFaceCacheRoot: cacheRoot
            ),
            .missing
        )
    }

    func testHuggingFaceStorageStatusRejectsInProgressNativeSnapshot() throws {
        let cacheRoot = try makeTemporaryDirectory()
        let defaultCheckpoints = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: cacheRoot)
            try? FileManager.default.removeItem(at: defaultCheckpoints)
        }

        let modelId = "org/native-partial-model"
        let snapshotPath = try makeNativeSnapshotDirectory(modelId: modelId, cacheRoot: cacheRoot)
        try Data("{}".utf8).write(to: snapshotPath.appendingPathComponent("config.json"))
        try Data([1]).write(to: snapshotPath.appendingPathComponent("model.safetensors"))
        try Data("in-progress".utf8).write(
            to: snapshotPath.appendingPathComponent(NativeSnapshotCompletionManifest.inProgressFilename)
        )

        guard case .incomplete(let message) = RuntimeManager.modelStorageStatus(
            modelId: modelId,
            checkpointsPath: defaultCheckpoints,
            huggingFaceCacheRoot: cacheRoot
        ) else {
            return XCTFail("Expected in-progress native snapshot to be incomplete")
        }

        XCTAssertTrue(message.contains("Native model download is still incomplete"))
    }

    func testDownloadedSnapshotPathRejectsInProgressNativeSnapshotWithWeights() throws {
        let cacheRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: cacheRoot) }

        let modelId = "org/native-partial-path-model"
        let snapshotPath = try makeNativeSnapshotDirectory(modelId: modelId, cacheRoot: cacheRoot)
        try Data("{}".utf8).write(to: snapshotPath.appendingPathComponent("config.json"))
        try Data([1]).write(to: snapshotPath.appendingPathComponent("model.safetensors"))
        try Data("in-progress".utf8).write(
            to: snapshotPath.appendingPathComponent(NativeSnapshotCompletionManifest.inProgressFilename)
        )

        XCTAssertNil(
            RuntimeManager.downloadedSnapshotPath(
                modelId: modelId,
                revision: "main",
                huggingFaceCacheRoot: cacheRoot
            )
        )
    }

    func testHuggingFaceStorageStatusValidatesNativeCompletionManifest() throws {
        let cacheRoot = try makeTemporaryDirectory()
        let defaultCheckpoints = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: cacheRoot)
            try? FileManager.default.removeItem(at: defaultCheckpoints)
        }

        let modelId = "org/native-complete-model"
        let snapshotPath = try makeNativeSnapshotDirectory(modelId: modelId, cacheRoot: cacheRoot)
        try Data("{}".utf8).write(to: snapshotPath.appendingPathComponent("config.json"))
        try Data([1]).write(to: snapshotPath.appendingPathComponent("model-00001-of-00002.safetensors"))
        try writeNativeCompletionMarker(
            at: snapshotPath,
            modelId: modelId,
            files: [
                HuggingFaceManifestFile(path: "config.json", size: 2, sha256: nil),
                HuggingFaceManifestFile(path: "model-00001-of-00002.safetensors", size: 1, sha256: nil),
                HuggingFaceManifestFile(path: "model-00002-of-00002.safetensors", size: 1, sha256: nil),
            ]
        )

        guard case .incomplete(let message) = RuntimeManager.modelStorageStatus(
            modelId: modelId,
            checkpointsPath: defaultCheckpoints,
            huggingFaceCacheRoot: cacheRoot
        ) else {
            return XCTFail("Expected native snapshot with missing marker file to be incomplete")
        }
        XCTAssertTrue(message.contains("model-00002-of-00002.safetensors"))

        try Data([1]).write(to: snapshotPath.appendingPathComponent("model-00002-of-00002.safetensors"))

        XCTAssertEqual(
            RuntimeManager.modelStorageStatus(
                modelId: modelId,
                checkpointsPath: defaultCheckpoints,
                huggingFaceCacheRoot: cacheRoot
            ),
            .downloaded
        )
    }

    func testAceStepStorageStatusRejectsInProgressContractMarker() throws {
        let checkpointsPath = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: checkpointsPath) }

        for component in ["acestep-v15-turbo", "vae", "Qwen3-Embedding-0.6B", "acestep-5Hz-lm-1.7B"] {
            let componentPath = checkpointsPath.appendingPathComponent(component)
            try FileManager.default.createDirectory(at: componentPath, withIntermediateDirectories: true)
            try Data([1]).write(to: componentPath.appendingPathComponent("model.safetensors"))
        }
        try Data("in-progress".utf8).write(
            to: checkpointsPath.appendingPathComponent(AceStepContractCompletionManifest.inProgressFilename)
        )
        try Data("in-progress".utf8).write(
            to: checkpointsPath.appendingPathComponent(NativeSnapshotCompletionManifest.inProgressFilename)
        )
        try writeNativeCompletionMarker(
            at: checkpointsPath,
            modelId: "ACE-Step/Ace-Step1.5",
            files: [
                HuggingFaceManifestFile(path: "missing-generic-snapshot-file.json", size: 1, sha256: nil),
            ]
        )

        guard case .incomplete(let message) = RuntimeManager.modelStorageStatus(
            modelId: "ACE-Step/acestep-v15-turbo-continuous",
            checkpointsPath: checkpointsPath
        ) else {
            return XCTFail("Expected in-progress ACE-Step contract to be incomplete")
        }
        XCTAssertTrue(message.contains("ACE-Step contract validation is incomplete"))
    }

    func testAceStepStorageStatusAcceptsCompleteContractMarkerAndIgnoresGenericNativeSnapshotMarkers() throws {
        let checkpointsPath = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: checkpointsPath) }

        for component in ["acestep-v15-turbo", "vae", "Qwen3-Embedding-0.6B", "acestep-5Hz-lm-1.7B"] {
            let componentPath = checkpointsPath.appendingPathComponent(component)
            try FileManager.default.createDirectory(at: componentPath, withIntermediateDirectories: true)
            try Data([1]).write(to: componentPath.appendingPathComponent("model.safetensors"))
        }
        try writeNativeCompletionMarker(
            at: checkpointsPath,
            modelId: "ACE-Step/Ace-Step1.5",
            files: [
                HuggingFaceManifestFile(path: "missing-generic-snapshot-file.json", size: 1, sha256: nil),
            ]
        )
        try writeAceStepContractCompletionMarker(at: checkpointsPath)

        XCTAssertEqual(
            RuntimeManager.modelStorageStatus(
                modelId: "ACE-Step/acestep-v15-turbo-continuous",
                checkpointsPath: checkpointsPath
            ),
            .downloaded
        )
    }

    func testAceStepStorageStatusRejectsInvalidContractMarker() throws {
        let checkpointsPath = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: checkpointsPath) }

        for component in ["acestep-v15-turbo", "vae", "Qwen3-Embedding-0.6B", "acestep-5Hz-lm-1.7B"] {
            let componentPath = checkpointsPath.appendingPathComponent(component)
            try FileManager.default.createDirectory(at: componentPath, withIntermediateDirectories: true)
            try Data([1]).write(to: componentPath.appendingPathComponent("model.safetensors"))
        }
        try Data("{}".utf8).write(
            to: checkpointsPath.appendingPathComponent(AceStepContractCompletionManifest.filename)
        )

        guard case .incomplete(let message) = RuntimeManager.modelStorageStatus(
            modelId: "ACE-Step/acestep-v15-turbo-continuous",
            checkpointsPath: checkpointsPath
        ) else {
            return XCTFail("Expected invalid ACE-Step contract marker to be incomplete")
        }
        XCTAssertTrue(message.contains("ACE-Step contract marker is invalid"))
    }

    func testPreferredRuntimeUsesValidInstalledRuntime() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let installed = root.appendingPathComponent("installed")
        let bundled = root.appendingPathComponent("bundled")
        try makeRuntimeBundle(at: installed, version: "0.2.0")
        try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)

        let selected = RuntimeManager.preferredRuntimeBundleURL(
            installed: installed,
            bundledCandidates: [bundled]
        )

        XCTAssertEqual(selected, installed)
    }

    func testPreferredRuntimeFallsBackWhenInstalledRuntimeIsInvalid() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let installed = root.appendingPathComponent("installed")
        let bundled = root.appendingPathComponent("bundled")
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        try makeRuntimeBundle(at: bundled, version: "0.1.0")

        let selected = RuntimeManager.preferredRuntimeBundleURL(
            installed: installed,
            bundledCandidates: [bundled]
        )

        XCTAssertEqual(selected, bundled)
    }

    func testPreferredRuntimeFallsBackWhenInstalledRuntimeIsMissingBasePython() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let installed = root.appendingPathComponent("installed")
        let bundled = root.appendingPathComponent("bundled")
        try makeRuntimeBundle(at: installed, version: "0.2.0")
        try makeRuntimeBundle(at: bundled, version: "0.1.0")
        try FileManager.default.removeItem(at: installed.appendingPathComponent("venv/bin/python"))

        let selected = RuntimeManager.preferredRuntimeBundleURL(
            installed: installed,
            bundledCandidates: [bundled]
        )

        XCTAssertEqual(selected, bundled)
    }

    func testRuntimeManifestSupportsBackendsAndProfiles() throws {
        let manifest = RuntimeManifest(
            runtimeVersion: "0.2.0",
            compatibilityApi: 1,
            supportedBackends: [.vlm, .image]
        )
        let profile = ModelCapabilityProfile(
            id: "org/model",
            name: "Model",
            subtitle: "Test",
            modelId: "org/model",
            modality: .vision,
            backend: .vlm,
            icon: "eye",
            downloadSizeGB: 1.0,
            estimatedMemoryGB: 1.0,
            runtime: ModelRuntimeRequirement(minVersion: "0.2.0", compatibilityApi: 1),
            parameters: [],
            presets: []
        )

        XCTAssertTrue(manifest.supports(backend: .vlm))
        XCTAssertFalse(manifest.supports(backend: .music))
        XCTAssertTrue(manifest.supports(profile: profile))
    }

    @MainActor
    func testRuntimeUpdateRefreshCanHideAutomaticDecodeFailures() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let channelURL = directory.appendingPathComponent("stable-channel.json")
        try Data("not json".utf8).write(to: channelURL)

        let manager = RuntimeUpdateManager()
        await manager.refreshStableChannel(channelURL: channelURL, reportFailures: false)

        XCTAssertEqual(manager.state, .idle)
    }

    @MainActor
    func testRuntimeUpdateRefreshReportsExplicitDecodeFailures() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let channelURL = directory.appendingPathComponent("stable-channel.json")
        try Data("not json".utf8).write(to: channelURL)

        let manager = RuntimeUpdateManager()
        await manager.refreshStableChannel(channelURL: channelURL)

        guard case .failed = manager.state else {
            XCTFail("Expected explicit runtime refresh failure to be surfaced")
            return
        }
    }

    @MainActor
    func testRuntimeUpdateRefreshReportsRemoteChannelHTTPFailures() async throws {
        RuntimeChannelURLProtocol.reset(statusCode: 500, data: Data())
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RuntimeChannelURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let manager = RuntimeUpdateManager(channelSession: session)
        await manager.refreshStableChannel(channelURL: URL(string: "https://channel.test/stable-channel.json")!)

        XCTAssertEqual(RuntimeChannelURLProtocol.requestCount(), 1)
        XCTAssertEqual(manager.state, .failed(RuntimeUpdateError.channelUnavailable.localizedDescription))
    }

    @MainActor
    func testRuntimeUpdateRefreshIgnoresStaleOlderRefreshResult() async throws {
        let slowData = try runtimeChannelData(runtimes: [makeRuntimeAsset(version: "0.1.1")])
        let fastData = try runtimeChannelData(runtimes: [makeRuntimeAsset(version: "0.1.2")])
        RuntimeChannelURLProtocol.resetRoutes([
            "/slow-channel.json": RuntimeChannelResponse(statusCode: 200, data: slowData, delay: 0.15),
            "/fast-channel.json": RuntimeChannelResponse(statusCode: 200, data: fastData)
        ])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RuntimeChannelURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let manager = RuntimeUpdateManager(
            currentManifestProvider: { self.makeRuntimeManifest(version: "0.1.0", compatibilityApi: 1) },
            channelSession: session
        )

        let slowTask = Task { @MainActor in
            await manager.refreshStableChannel(
                channelURL: URL(string: "https://channel.test/slow-channel.json")!
            )
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        await manager.refreshStableChannel(
            channelURL: URL(string: "https://channel.test/fast-channel.json")!
        )
        await slowTask.value

        guard case .available(let asset) = manager.state else {
            XCTFail("Expected the newer refresh result to remain available")
            return
        }
        XCTAssertEqual(asset.version, "0.1.2")
        XCTAssertEqual(manager.channel?.runtimes.first?.version, "0.1.2")
    }

    @MainActor
    func testRuntimeUpdateRefreshFindsNewestCompatibleRuntime() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let channelURL = directory.appendingPathComponent("stable-channel.json")
        try writeRuntimeChannel(
            to: channelURL,
            runtimes: [
                makeRuntimeAsset(version: "0.1.0"),
                makeRuntimeAsset(version: "0.0.9"),
                makeRuntimeAsset(version: "0.1.5", arch: "x86_64"),
                makeRuntimeAsset(version: "0.1.6", platform: "linux"),
                makeRuntimeAsset(version: "0.1.7", compatibilityApi: 2),
                makeRuntimeAsset(version: "0.1.1"),
                makeRuntimeAsset(version: "0.1.2"),
            ]
        )

        let currentManifest = makeRuntimeManifest(version: "0.1.0", compatibilityApi: 1)
        let manager = RuntimeUpdateManager(currentManifestProvider: { currentManifest })
        await manager.refreshStableChannel(channelURL: channelURL)

        guard case .available(let asset) = manager.state else {
            XCTFail("Expected compatible newer runtime to be available")
            return
        }
        XCTAssertEqual(asset.version, "0.1.2")
        XCTAssertEqual(asset.id, "macos-arm64-base-0.1.2")
        XCTAssertEqual(manager.availableRuntime, asset)
    }

    @MainActor
    func testRuntimeUpdateRefreshFindsMissingMusicComponent() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let channelURL = directory.appendingPathComponent("stable-channel.json")
        try writeRuntimeChannel(
            to: channelURL,
            runtimes: [
                makeRuntimeAsset(version: "0.1.2", component: "base"),
                makeRuntimeAsset(version: "0.1.2", component: "music"),
            ]
        )

        let baseManifest = makeRuntimeManifest(version: "0.1.2", compatibilityApi: 1)
        let manager = RuntimeUpdateManager(
            currentManifestProvider: { baseManifest },
            currentComponentManifestProvider: { component in
                component == .base ? baseManifest : nil
            }
        )
        await manager.refreshStableChannel(channelURL: channelURL, component: .music)

        guard case .available(let asset) = manager.state else {
            XCTFail("Expected compatible music runtime component to be available")
            return
        }
        XCTAssertEqual(asset.component, .music)
        XCTAssertEqual(asset.version, "0.1.2")
        XCTAssertEqual(asset.id, "macos-arm64-music-0.1.2")
    }

    @MainActor
    func testRuntimeUpdateRefreshRequiresBaseForMusicComponent() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let channelURL = directory.appendingPathComponent("stable-channel.json")
        try writeRuntimeChannel(
            to: channelURL,
            runtimes: [
                makeRuntimeAsset(version: "0.1.2", component: "music"),
            ]
        )

        let manager = RuntimeUpdateManager(
            currentManifestProvider: { nil },
            currentComponentManifestProvider: { _ in nil }
        )
        await manager.refreshStableChannel(channelURL: channelURL, component: .music)

        XCTAssertEqual(manager.state, .idle)
    }

    @MainActor
    func testRuntimeUpdateRefreshIgnoresRuntimeRequiringNewerApp() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let channelURL = directory.appendingPathComponent("stable-channel.json")
        try writeRuntimeChannel(
            to: channelURL,
            runtimes: [
                makeRuntimeAsset(version: "0.1.2", minAppVersion: "1.0.0"),
                makeRuntimeAsset(version: "0.1.3", minAppVersion: "9.0.0"),
            ]
        )

        let currentManifest = makeRuntimeManifest(version: "0.1.0", compatibilityApi: 1)
        let manager = RuntimeUpdateManager(
            currentManifestProvider: { currentManifest },
            appVersionProvider: { "1.0.6" }
        )
        await manager.refreshStableChannel(channelURL: channelURL)

        guard case .available(let asset) = manager.state else {
            XCTFail("Expected compatible runtime for current app version to be available")
            return
        }
        XCTAssertEqual(asset.version, "0.1.2")
        XCTAssertEqual(asset.minAppVersion, "1.0.0")
        XCTAssertEqual(manager.newerRuntimeRequiringAppUpdate?.runtime.version, "0.1.3")
        XCTAssertEqual(manager.newerRuntimeRequiringAppUpdate?.requiredAppVersion, "9.0.0")
        XCTAssertEqual(manager.newerRuntimeRequiringAppUpdate?.currentAppVersion, "1.0.6")
    }

    @MainActor
    func testRuntimeUpdateRefreshReportsRuntimeRequiringNewerAppWhenNoCompatibleRuntime() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let channelURL = directory.appendingPathComponent("stable-channel.json")
        try writeRuntimeChannel(
            to: channelURL,
            runtimes: [
                makeRuntimeAsset(version: "0.1.2", minAppVersion: "9.0.0"),
            ]
        )

        let currentManifest = makeRuntimeManifest(version: "0.1.0", compatibilityApi: 1)
        let manager = RuntimeUpdateManager(
            currentManifestProvider: { currentManifest },
            appVersionProvider: { "1.0.6" }
        )
        await manager.refreshStableChannel(channelURL: channelURL)

        guard case .requiresAppUpdate(let requirement) = manager.state else {
            XCTFail("Expected newer runtime to report app update requirement")
            return
        }
        XCTAssertEqual(requirement.runtime.version, "0.1.2")
        XCTAssertEqual(requirement.requiredAppVersion, "9.0.0")
        XCTAssertEqual(requirement.currentAppVersion, "1.0.6")
        XCTAssertEqual(manager.newerRuntimeRequiringAppUpdate, requirement)
        XCTAssertNil(manager.availableRuntime)
    }

    @MainActor
    func testRuntimeUpdateRefreshIgnoresChannelsWithoutCompatibleRuntime() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let channelURL = directory.appendingPathComponent("stable-channel.json")
        try writeRuntimeChannel(
            to: channelURL,
            runtimes: [
                makeRuntimeAsset(version: "0.1.0"),
                makeRuntimeAsset(version: "0.0.9"),
                makeRuntimeAsset(version: "0.1.5", arch: "x86_64"),
                makeRuntimeAsset(version: "0.1.6", platform: "linux"),
                makeRuntimeAsset(version: "0.1.7", compatibilityApi: 2),
            ]
        )

        let currentManifest = makeRuntimeManifest(version: "0.1.0", compatibilityApi: 1)
        let manager = RuntimeUpdateManager(currentManifestProvider: { currentManifest })
        await manager.refreshStableChannel(channelURL: channelURL)

        XCTAssertEqual(manager.state, .idle)
        XCTAssertNil(manager.availableRuntime)
    }

    @MainActor
    func testRuntimeInstallVerifiesChecksumExtractsArchiveAndActivatesRuntime() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let runtimeRoot = directory.appendingPathComponent("runtime-macos-arm64")
        try makeRuntimeBundle(at: runtimeRoot, version: "0.1.1")
        let archiveURL = directory.appendingPathComponent("runtime-macos-arm64-0.1.1.zip")
        try makeZipArchive(from: runtimeRoot, at: archiveURL)

        let installRoot = directory.appendingPathComponent("installed-runtimes")
        let checksum = try SHA256Checksum.hexDigest(for: archiveURL)
        let asset = RuntimeReleaseAsset(
            version: "0.1.1",
            platform: "macos",
            arch: "arm64",
            url: archiveURL,
            sha256: checksum,
            sizeBytes: try archiveSizeBytes(archiveURL),
            compatibilityApi: 1
        )
        let manager = RuntimeUpdateManager(
            currentManifestProvider: { self.makeRuntimeManifest(version: "0.1.0", compatibilityApi: 1) },
            runtimeArchiveInstaller: { archive, _ in
                try RuntimeManager.installRuntimeArchive(archive, installRoot: installRoot)
            }
        )
        let targetExpectation = expectation(description: "Runtime install target is published")
        targetExpectation.assertForOverFulfill = false
        var publishedTarget: RuntimeReleaseAsset?
        let targetCancellable = manager.$installingRuntime.sink { target in
            guard let target, publishedTarget == nil else { return }
            publishedTarget = target
            targetExpectation.fulfill()
        }
        defer { targetCancellable.cancel() }

        await manager.installRuntime(asset)

        await fulfillment(of: [targetExpectation], timeout: 1)
        XCTAssertEqual(publishedTarget?.version, "0.1.1")
        XCTAssertNil(manager.installingRuntime)
        XCTAssertEqual(manager.state, .installed("0.1.1"))
        let currentURL = installRoot.appendingPathComponent("current")
        XCTAssertEqual(RuntimeManager.runtimeManifest(at: currentURL)?.runtimeVersion, "0.1.1")
        XCTAssertTrue(RuntimeManager.isRuntimeBundleStructurallyValid(currentURL))
        XCTAssertTrue(
            FileManager.default.isExecutableFile(
                atPath: currentURL.appendingPathComponent("acestep-venv/bin/python").path
            )
        )
    }

    func testRuntimeComponentInstallAllowsMusicPythonSymlinkToBaseRuntime() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let baseRuntimeRoot = directory.appendingPathComponent("active-base")
        try makeBaseRuntimeBundle(at: baseRuntimeRoot, version: "0.1.1")

        let componentRoot = directory.appendingPathComponent("runtime-music-macos-arm64")
        try makeMusicRuntimeComponent(at: componentRoot, version: "0.1.1")
        let archiveURL = directory.appendingPathComponent("runtime-music-macos-arm64-0.1.1.zip")
        try makeZipArchive(from: componentRoot, at: archiveURL)

        let installedURL = try RuntimeManager.installRuntimeComponentArchive(
            archiveURL,
            component: .music,
            activeRuntimeRoot: baseRuntimeRoot,
            installRoot: directory.appendingPathComponent("installed-runtimes")
        )

        XCTAssertEqual(installedURL, baseRuntimeRoot)
        XCTAssertTrue(RuntimeManager.isRuntimeComponentStructurallyValid(.music, at: baseRuntimeRoot))
        XCTAssertEqual(RuntimeManager.runtimeManifest(at: baseRuntimeRoot, component: .music)?.component, .music)
        XCTAssertTrue(
            FileManager.default.isExecutableFile(
                atPath: baseRuntimeRoot.appendingPathComponent("acestep-venv/bin/python").path
            )
        )
    }

    func testLegacyMusicRuntimeComponentDoesNotRequireMagentaPython() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let baseRuntimeRoot = directory.appendingPathComponent("active-base")
        try makeBaseRuntimeBundle(at: baseRuntimeRoot, version: "0.1.6")
        try makeMusicRuntimeComponent(
            at: baseRuntimeRoot,
            version: "0.1.6",
            includeMagentaRuntime: false,
            declaresRealtimeMusic: false
        )

        XCTAssertTrue(RuntimeManager.isRuntimeComponentStructurallyValid(.music, at: baseRuntimeRoot))
    }

    func testRealtimeMusicRuntimeComponentRequiresMagentaPython() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let baseRuntimeRoot = directory.appendingPathComponent("active-base")
        try makeBaseRuntimeBundle(at: baseRuntimeRoot, version: "0.1.7")
        try makeMusicRuntimeComponent(
            at: baseRuntimeRoot,
            version: "0.1.7",
            includeMagentaRuntime: false,
            declaresRealtimeMusic: true
        )

        XCTAssertFalse(RuntimeManager.isRuntimeComponentStructurallyValid(.music, at: baseRuntimeRoot))
    }

    func testRuntimeBundleValidityDoesNotRequireHuggingFaceDownloadHelper() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let runtimeRoot = directory.appendingPathComponent("runtime-macos-arm64")
        try makeRuntimeBundle(at: runtimeRoot, version: "0.1.1")

        XCTAssertTrue(RuntimeManager.isRuntimeBundleStructurallyValid(runtimeRoot))
    }

    func testRuntimeDownloadProgressCalculatesRemainingTime() {
        let progress = RuntimeDownloadProgress(
            downloadedBytes: 512,
            totalBytes: 1_024,
            bytesPerSecond: 256
        )

        XCTAssertEqual(progress.fractionCompleted, 0.5)
        XCTAssertEqual(progress.estimatedSecondsRemaining, 2)
    }

    func testRuntimeDownloadSpeedTrackerMeasuresRateAndResetsOnRegression() {
        var tracker = RuntimeDownloadSpeedTracker()
        let start = Date(timeIntervalSince1970: 100)

        XCTAssertNil(
            tracker.bytesPerSecond(
                for: RuntimeDownloadProgress(downloadedBytes: 100, totalBytes: 1_000),
                at: start
            )
        )

        let measuredRate = tracker.bytesPerSecond(
            for: RuntimeDownloadProgress(downloadedBytes: 600, totalBytes: 1_000),
            at: start.addingTimeInterval(2)
        )
        XCTAssertEqual(measuredRate ?? -1, 250, accuracy: 0.001)

        XCTAssertNil(
            tracker.bytesPerSecond(
                for: RuntimeDownloadProgress(downloadedBytes: 200, totalBytes: 1_000),
                at: start.addingTimeInterval(3)
            )
        )

        let resetRate = tracker.bytesPerSecond(
            for: RuntimeDownloadProgress(downloadedBytes: 700, totalBytes: 1_000),
            at: start.addingTimeInterval(5)
        )
        XCTAssertEqual(resetRate ?? -1, 250, accuracy: 0.001)
    }

    @MainActor
    func testRuntimeInstallReportsRemoteArchiveDownloadProgress() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let runtimeRoot = directory.appendingPathComponent("installed-runtime")
        try makeRuntimeBundle(at: runtimeRoot, version: "0.1.1")
        let archiveData = Data((0..<4096).map { UInt8($0 % 255) })
        let archiveURL = directory.appendingPathComponent("runtime.zip")
        try archiveData.write(to: archiveURL)
        let archiveSHA256 = try SHA256Checksum.hexDigest(for: archiveURL)

        RuntimeArchiveURLProtocol.reset(data: archiveData)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RuntimeArchiveURLProtocol.self]

        let recorder = RuntimeUpdateStateRecorder()
        let manager = RuntimeUpdateManager(
            currentManifestProvider: { nil },
            runtimeArchiveInstaller: { archive, _ in
                guard (try? Data(contentsOf: archive)) == archiveData else {
                    throw RuntimeUpdateError.invalidRuntime
                }
                return runtimeRoot
            },
            runtimeArchiveDownloadConfiguration: configuration,
            runtimeArchiveCacheDirectory: directory.appendingPathComponent("runtime-cache")
        )
        let cancellable = manager.$state.sink { state in
            recorder.append(state)
        }
        let progressExpectation = expectation(description: "Runtime download progress is published")
        progressExpectation.assertForOverFulfill = false
        var didReceiveExpectedProgress = false
        let progressCancellable = manager.$runtimeDownloadProgress.sink { progress in
            guard !didReceiveExpectedProgress,
                  let progress,
                  progress.downloadedBytes > 0,
                  progress.downloadedBytes <= Int64(archiveData.count),
                  progress.totalBytes == Int64(archiveData.count) else {
                return
            }
            didReceiveExpectedProgress = true
            progressExpectation.fulfill()
        }
        defer {
            cancellable.cancel()
            progressCancellable.cancel()
        }

        let asset = RuntimeReleaseAsset(
            version: "0.1.1",
            platform: "macos",
            arch: "arm64",
            url: URL(string: "https://runtime.test/runtime.zip")!,
            sha256: archiveSHA256,
            sizeBytes: Int64(archiveData.count),
            compatibilityApi: 1
        )

        let installTask = Task { @MainActor in
            await manager.installRuntime(asset)
        }
        await fulfillment(of: [progressExpectation], timeout: 3)
        await installTask.value

        XCTAssertEqual(manager.state, .installed("0.1.1"))
        XCTAssertTrue(
            recorder.states().contains { state in
                if case .installing(let progress) = state, let progress {
                    return progress > 0 && progress <= 1
                }
                return false
            },
            "Expected runtime installer to publish determinate archive download progress"
        )
        XCTAssertTrue(didReceiveExpectedProgress)
    }

    @MainActor
    func testRuntimeInstallThrottlesPublishedRemoteArchiveDownloadProgress() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let runtimeRoot = directory.appendingPathComponent("installed-runtime")
        try makeRuntimeBundle(at: runtimeRoot, version: "0.1.1")
        let archiveData = Data((0..<4096).map { UInt8($0 % 255) })
        let archiveURL = directory.appendingPathComponent("runtime.zip")
        try archiveData.write(to: archiveURL)
        let archiveSHA256 = try SHA256Checksum.hexDigest(for: archiveURL)

        RuntimeArchiveURLProtocol.reset(data: archiveData)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RuntimeArchiveURLProtocol.self]

        var publishedProgress: [RuntimeDownloadProgress] = []
        let manager = RuntimeUpdateManager(
            currentManifestProvider: { nil },
            runtimeArchiveInstaller: { archive, _ in
                guard (try? Data(contentsOf: archive)) == archiveData else {
                    throw RuntimeUpdateError.invalidRuntime
                }
                return runtimeRoot
            },
            runtimeArchiveDownloadConfiguration: configuration,
            runtimeArchiveCacheDirectory: directory.appendingPathComponent("runtime-cache"),
            runtimeDownloadProgressPublishInterval: 60
        )
        let progressCancellable = manager.$runtimeDownloadProgress.sink { progress in
            guard let progress else { return }
            publishedProgress.append(progress)
        }
        defer { progressCancellable.cancel() }

        let asset = RuntimeReleaseAsset(
            version: "0.1.1",
            platform: "macos",
            arch: "arm64",
            url: URL(string: "https://runtime.test/runtime.zip")!,
            sha256: archiveSHA256,
            sizeBytes: Int64(archiveData.count),
            compatibilityApi: 1
        )

        await manager.installRuntime(asset)

        XCTAssertEqual(manager.state, .installed("0.1.1"))
        XCTAssertEqual(publishedProgress.map(\.downloadedBytes), [0, Int64(archiveData.count)])
    }

    @MainActor
    func testRuntimeInstallReportsActivationProgressFromInstaller() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let runtimeRoot = directory.appendingPathComponent("installed-runtime")
        try makeRuntimeBundle(at: runtimeRoot, version: "0.1.1")
        let archiveURL = directory.appendingPathComponent("runtime.zip")
        try Data("runtime archive".utf8).write(to: archiveURL)
        let archiveSHA256 = try SHA256Checksum.hexDigest(for: archiveURL)

        let manager = RuntimeUpdateManager(
            currentManifestProvider: { nil },
            runtimeArchiveInstaller: { _, progressHandler in
                progressHandler(RuntimeActivationProgress(
                    title: "Expanding test runtime",
                    detail: "Copying staged files",
                    completedStep: 3,
                    totalSteps: 5
                ))
                return runtimeRoot
            }
        )

        let progressExpectation = expectation(description: "Runtime activation progress is published")
        progressExpectation.assertForOverFulfill = false
        let progressCancellable = manager.$runtimeActivationProgress.sink { progress in
            guard progress?.title == "Expanding test runtime",
                  progress?.detail == "Copying staged files",
                  progress?.completedStep == 3,
                  progress?.totalSteps == 5 else {
                return
            }
            progressExpectation.fulfill()
        }
        defer { progressCancellable.cancel() }

        let asset = RuntimeReleaseAsset(
            version: "0.1.1",
            platform: "macos",
            arch: "arm64",
            url: archiveURL,
            sha256: archiveSHA256,
            sizeBytes: try archiveSizeBytes(archiveURL),
            compatibilityApi: 1
        )

        let installTask = Task { @MainActor in
            await manager.installRuntime(asset)
        }
        await fulfillment(of: [progressExpectation], timeout: 2)
        await installTask.value

        XCTAssertEqual(manager.state, .installed("0.1.1"))
        XCTAssertNil(manager.runtimeActivationProgress)
    }

    @MainActor
    func testRuntimeRefreshDoesNotClobberActiveInstallState() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let runtimeRoot = directory.appendingPathComponent("installed-runtime")
        try makeRuntimeBundle(at: runtimeRoot, version: "0.1.1")
        let archiveURL = directory.appendingPathComponent("runtime.zip")
        try Data("runtime archive".utf8).write(to: archiveURL)
        let archiveSHA256 = try SHA256Checksum.hexDigest(for: archiveURL)
        let channelURL = directory.appendingPathComponent("stable-channel.json")
        try writeRuntimeChannel(
            to: channelURL,
            runtimes: [
                makeRuntimeAsset(version: "0.1.2")
            ]
        )

        let installerStarted = expectation(description: "Runtime installer started")
        let releaseInstaller = DispatchSemaphore(value: 0)
        let manager = RuntimeUpdateManager(
            currentManifestProvider: { self.makeRuntimeManifest(version: "0.1.0", compatibilityApi: 1) },
            runtimeArchiveInstaller: { _, _ in
                installerStarted.fulfill()
                releaseInstaller.wait()
                return runtimeRoot
            }
        )

        let asset = RuntimeReleaseAsset(
            version: "0.1.1",
            platform: "macos",
            arch: "arm64",
            url: archiveURL,
            sha256: archiveSHA256,
            sizeBytes: try archiveSizeBytes(archiveURL),
            compatibilityApi: 1
        )

        let installTask = Task { @MainActor in
            await manager.installRuntime(asset)
        }
        await fulfillment(of: [installerStarted], timeout: 2)

        await manager.refreshStableChannel(channelURL: channelURL)
        guard case .installing = manager.state else {
            releaseInstaller.signal()
            XCTFail("Expected active install state to be preserved during refresh")
            await installTask.value
            return
        }

        releaseInstaller.signal()
        await installTask.value
        XCTAssertEqual(manager.state, .installed("0.1.1"))
    }

    @MainActor
    func testRuntimeInstallResumesRemoteArchiveDownloadAfterTransientFailure() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let runtimeRoot = directory.appendingPathComponent("installed-runtime")
        try makeRuntimeBundle(at: runtimeRoot, version: "0.1.1")
        let archiveData = Data((0..<8192).map { UInt8($0 % 255) })
        let archiveURL = directory.appendingPathComponent("runtime.zip")
        try archiveData.write(to: archiveURL)
        let archiveSHA256 = try SHA256Checksum.hexDigest(for: archiveURL)

        RuntimeArchiveURLProtocol.reset(data: archiveData, failFirstRequestAfterFirstChunk: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RuntimeArchiveURLProtocol.self]

        let manager = RuntimeUpdateManager(
            currentManifestProvider: { nil },
            runtimeArchiveInstaller: { archive, _ in
                guard (try? Data(contentsOf: archive)) == archiveData else {
                    throw RuntimeUpdateError.invalidRuntime
                }
                return runtimeRoot
            },
            runtimeArchiveDownloadConfiguration: configuration,
            runtimeArchiveCacheDirectory: directory.appendingPathComponent("runtime-cache")
        )

        let asset = RuntimeReleaseAsset(
            version: "0.1.1",
            platform: "macos",
            arch: "arm64",
            url: URL(string: "https://runtime.test/runtime.zip")!,
            sha256: archiveSHA256,
            sizeBytes: Int64(archiveData.count),
            compatibilityApi: 1
        )

        await manager.installRuntime(asset)

        XCTAssertEqual(manager.state, .installed("0.1.1"))
        XCTAssertTrue(
            RuntimeArchiveURLProtocol.recordedRangeHeaders().contains { range in
                range?.hasPrefix("bytes=") == true
            },
            "Expected retry to resume the runtime archive download with a Range request"
        )
    }

    @MainActor
    func testRuntimeInstallDoesNotRetryCancelledArchiveDownload() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        RuntimeArchiveURLProtocol.reset(data: Data([1, 2, 3, 4]), failEveryRequestWith: URLError(.cancelled))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RuntimeArchiveURLProtocol.self]

        let manager = RuntimeUpdateManager(
            currentManifestProvider: { nil },
            runtimeArchiveInstaller: { _, _ in
                throw RuntimeUpdateError.invalidRuntime
            },
            runtimeArchiveDownloadConfiguration: configuration,
            runtimeArchiveCacheDirectory: directory.appendingPathComponent("runtime-cache")
        )

        let asset = RuntimeReleaseAsset(
            version: "0.1.1",
            platform: "macos",
            arch: "arm64",
            url: URL(string: "https://runtime.test/runtime.zip")!,
            sha256: String(repeating: "0", count: 64),
            sizeBytes: 4,
            compatibilityApi: 1
        )

        await manager.installRuntime(asset)

        XCTAssertEqual(RuntimeArchiveURLProtocol.requestCount(), 1)
        if case .failed = manager.state {
        } else {
            XCTFail("Expected cancelled archive download to fail without retrying")
        }
    }

    @MainActor
    func testRuntimeBootstrapInstallsWhenNoRuntimeIsActive() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let runtimeRoot = directory.appendingPathComponent("runtime-macos-arm64")
        try makeRuntimeBundle(at: runtimeRoot, version: "0.1.1")
        let archiveURL = directory.appendingPathComponent("runtime-macos-arm64-0.1.1.zip")
        try makeZipArchive(from: runtimeRoot, at: archiveURL)

        let installRoot = directory.appendingPathComponent("installed-runtimes")
        let checksum = try SHA256Checksum.hexDigest(for: archiveURL)
        let channelURL = directory.appendingPathComponent("stable-channel.json")
        try writeRuntimeChannel(
            to: channelURL,
            runtimes: [
                makeRuntimeAsset(
                    version: "0.1.1",
                    url: archiveURL,
                    sha256: checksum,
                    sizeBytes: try archiveSizeBytes(archiveURL)
                )
            ]
        )
        let manager = RuntimeUpdateManager(
            currentManifestProvider: { nil },
            runtimeArchiveInstaller: { archive, _ in
                try RuntimeManager.installRuntimeArchive(archive, installRoot: installRoot)
            }
        )

        await manager.bootstrapStableRuntimeIfNeeded(channelURL: channelURL)

        XCTAssertEqual(manager.state, .installed("0.1.1"))
        XCTAssertTrue(
            RuntimeManager.isRuntimeBundleStructurallyValid(
                installRoot.appendingPathComponent("current")
            )
        )
    }

    @MainActor
    func testRuntimeBackgroundBootstrapInstallsAfterCallerReturns() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let runtimeRoot = directory.appendingPathComponent("runtime-macos-arm64")
        try makeRuntimeBundle(at: runtimeRoot, version: "0.1.1")
        let archiveURL = directory.appendingPathComponent("runtime-macos-arm64-0.1.1.zip")
        try makeZipArchive(from: runtimeRoot, at: archiveURL)

        let installRoot = directory.appendingPathComponent("installed-runtimes")
        let checksum = try SHA256Checksum.hexDigest(for: archiveURL)
        let channelURL = directory.appendingPathComponent("stable-channel.json")
        try writeRuntimeChannel(
            to: channelURL,
            runtimes: [
                makeRuntimeAsset(
                    version: "0.1.1",
                    url: archiveURL,
                    sha256: checksum,
                    sizeBytes: try archiveSizeBytes(archiveURL)
                )
            ]
        )
        let manager = RuntimeUpdateManager(
            currentManifestProvider: { nil },
            runtimeArchiveInstaller: { archive, _ in
                try RuntimeManager.installRuntimeArchive(archive, installRoot: installRoot)
            }
        )

        manager.bootstrapStableRuntimeInBackground(channelURL: channelURL)

        let didInstall = await waitForRuntimeUpdateState(manager) { state in
            state == .installed("0.1.1")
        }
        XCTAssertTrue(didInstall)
        XCTAssertTrue(
            RuntimeManager.isRuntimeBundleStructurallyValid(
                installRoot.appendingPathComponent("current")
            )
        )
    }

    @MainActor
    func testRuntimeBackgroundBootstrapQueuesRequestWhileInstallIsActive() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let runtimeRoot1 = directory.appendingPathComponent("runtime-macos-arm64-0.1.1")
        try makeRuntimeBundle(at: runtimeRoot1, version: "0.1.1")
        let archiveURL1 = directory.appendingPathComponent("runtime-macos-arm64-0.1.1.zip")
        try makeZipArchive(from: runtimeRoot1, at: archiveURL1)

        let runtimeRoot2 = directory.appendingPathComponent("runtime-macos-arm64-0.1.2")
        try makeRuntimeBundle(at: runtimeRoot2, version: "0.1.2")
        let archiveURL2 = directory.appendingPathComponent("runtime-macos-arm64-0.1.2.zip")
        try makeZipArchive(from: runtimeRoot2, at: archiveURL2)

        let channelURL1 = directory.appendingPathComponent("stable-channel-0.1.1.json")
        try writeRuntimeChannel(
            to: channelURL1,
            runtimes: [
                makeRuntimeAsset(
                    version: "0.1.1",
                    url: archiveURL1,
                    sha256: try SHA256Checksum.hexDigest(for: archiveURL1),
                    sizeBytes: try archiveSizeBytes(archiveURL1)
                )
            ]
        )
        let channelURL2 = directory.appendingPathComponent("stable-channel-0.1.2.json")
        try writeRuntimeChannel(
            to: channelURL2,
            runtimes: [
                makeRuntimeAsset(
                    version: "0.1.2",
                    url: archiveURL2,
                    sha256: try SHA256Checksum.hexDigest(for: archiveURL2),
                    sizeBytes: try archiveSizeBytes(archiveURL2)
                )
            ]
        )

        let recorder = RuntimeInstallVersionRecorder()
        let installerStarted = expectation(description: "First runtime installer started")
        let releaseInstaller = DispatchSemaphore(value: 0)
        let manager = RuntimeUpdateManager(
            currentManifestProvider: { nil },
            runtimeArchiveInstaller: { archive, _ in
                if archive == archiveURL1 {
                    recorder.append("0.1.1")
                    installerStarted.fulfill()
                    releaseInstaller.wait()
                    return runtimeRoot1
                }
                recorder.append("0.1.2")
                return runtimeRoot2
            }
        )

        manager.bootstrapStableRuntimeInBackground(channelURL: channelURL1)
        await fulfillment(of: [installerStarted], timeout: 2)

        manager.bootstrapStableRuntimeInBackground(channelURL: channelURL2, reportFailures: true)
        releaseInstaller.signal()

        let didInstallQueuedRuntime = await waitForRuntimeUpdateState(manager, timeout: 3) { state in
            state == .installed("0.1.2")
        }

        XCTAssertTrue(didInstallQueuedRuntime)
        XCTAssertEqual(recorder.versions(), ["0.1.1", "0.1.2"])
    }

    @MainActor
    func testRuntimeBootstrapDoesNotReinstallCurrentRuntime() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let channelURL = directory.appendingPathComponent("stable-channel.json")
        try writeRuntimeChannel(
            to: channelURL,
            runtimes: [
                makeRuntimeAsset(version: "0.1.0")
            ]
        )
        let recorder = InstallerCallRecorder()
        let manager = RuntimeUpdateManager(
            currentManifestProvider: { self.makeRuntimeManifest(version: "0.1.0", compatibilityApi: 1) },
            runtimeArchiveInstaller: { _, _ in
                recorder.wasCalled = true
                return directory
            }
        )

        await manager.bootstrapStableRuntimeIfNeeded(channelURL: channelURL)

        XCTAssertFalse(recorder.wasCalled)
        XCTAssertEqual(manager.state, .idle)
    }

    @MainActor
    func testRuntimeInstallRejectsChecksumMismatchBeforeInstalling() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let archiveURL = directory.appendingPathComponent("runtime-macos-arm64-0.1.1.zip")
        try Data("not a runtime archive".utf8).write(to: archiveURL)
        let recorder = InstallerCallRecorder()
        let asset = RuntimeReleaseAsset(
            version: "0.1.1",
            platform: "macos",
            arch: "arm64",
            url: archiveURL,
            sha256: String(repeating: "0", count: 64),
            sizeBytes: try archiveSizeBytes(archiveURL),
            compatibilityApi: 1
        )
        let manager = RuntimeUpdateManager(
            runtimeArchiveInstaller: { _, _ in
                recorder.wasCalled = true
                return directory
            }
        )

        await manager.installRuntime(asset)

        XCTAssertFalse(recorder.wasCalled)
        XCTAssertEqual(manager.state, .failed(RuntimeUpdateError.checksumMismatch.localizedDescription))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MLXtraTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeNativeSnapshotDirectory(modelId: String, cacheRoot: URL) throws -> URL {
        let modelCachePath = RuntimeManager.modelCachePath(modelId: modelId, huggingFaceCacheRoot: cacheRoot)
        let snapshotPath = modelCachePath
            .appendingPathComponent("snapshots")
            .appendingPathComponent("revision")
        try FileManager.default.createDirectory(at: snapshotPath, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: modelCachePath.appendingPathComponent("refs"),
            withIntermediateDirectories: true
        )
        try Data("revision".utf8).write(to: modelCachePath.appendingPathComponent("refs/main"))
        return snapshotPath
    }

    private func writeNativeCompletionMarker(
        at snapshotPath: URL,
        modelId: String,
        files: [HuggingFaceManifestFile]
    ) throws {
        let manifest = HuggingFaceManifest(
            repoID: modelId,
            revision: "main",
            resolvedRevision: "revision",
            files: files
        )
        let data = try JSONEncoder().encode(NativeSnapshotCompletionManifest(manifest: manifest))
        try data.write(to: snapshotPath.appendingPathComponent(NativeSnapshotCompletionManifest.filename))
    }

    private func writeAceStepContractCompletionMarker(at checkpointsPath: URL) throws {
        let marker = AceStepContractCompletionManifest(
            plan: AceStepDownloadPlan(
                repoID: "ACE-Step/Ace-Step1.5",
                requiredComponents: ["acestep-v15-turbo", "vae", "Qwen3-Embedding-0.6B", "acestep-5Hz-lm-1.7B"],
                checkpointsRoot: checkpointsPath
            )
        )
        let data = try JSONEncoder().encode(marker)
        try data.write(to: checkpointsPath.appendingPathComponent(AceStepContractCompletionManifest.filename))
    }

    @MainActor
    private func waitForRuntimeUpdateState(
        _ manager: RuntimeUpdateManager,
        timeout: TimeInterval = 2,
        predicate: (RuntimeUpdateManager.InstallState) -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate(manager.state) {
                return true
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return predicate(manager.state)
    }

    private func makeRuntimeBundle(at url: URL, version: String) throws {
        try FileManager.default.createDirectory(at: url.appendingPathComponent("venv/bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("acestep-venv/bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent("python/Frameworks/Versions/3.12"),
            withIntermediateDirectories: true
        )
        try writeExecutableFile(at: url.appendingPathComponent("venv/bin/python"))
        try writeExecutableFile(at: url.appendingPathComponent("acestep-venv/bin/python"))
        FileManager.default.createFile(atPath: url.appendingPathComponent("acestep_download_helper.py").path, contents: Data())
        let manifest = makeRuntimeManifest(version: version, compatibilityApi: 1)
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: url.appendingPathComponent("runtime-manifest.json"))
    }

    private func makeBaseRuntimeBundle(at url: URL, version: String) throws {
        try FileManager.default.createDirectory(at: url.appendingPathComponent("venv/bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent("python/Frameworks/Versions/3.12/bin"),
            withIntermediateDirectories: true
        )
        try writeExecutableFile(at: url.appendingPathComponent("venv/bin/python"))
        try writeExecutableFile(at: url.appendingPathComponent("python/Frameworks/Versions/3.12/bin/python3"))
        let manifest = makeRuntimeManifest(version: version, compatibilityApi: 1)
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: url.appendingPathComponent("runtime-manifest.json"))
    }

    private func makeMusicRuntimeComponent(
        at url: URL,
        version: String,
        includeMagentaRuntime: Bool = true,
        declaresRealtimeMusic: Bool = true
    ) throws {
        try FileManager.default.createDirectory(at: url.appendingPathComponent("acestep-venv/bin"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: url.appendingPathComponent("acestep-venv/bin/python").path,
            withDestinationPath: "../../python/Frameworks/Versions/3.12/bin/python3"
        )
        if includeMagentaRuntime {
            try FileManager.default.createDirectory(at: url.appendingPathComponent("magenta-venv/bin"), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(
                atPath: url.appendingPathComponent("magenta-venv/bin/python").path,
                withDestinationPath: "../../python/Frameworks/Versions/3.12/bin/python3"
            )
        }
        FileManager.default.createFile(atPath: url.appendingPathComponent("acestep_download_helper.py").path, contents: Data())
        let manifest = RuntimeManifest(
            runtimeVersion: version,
            compatibilityApi: 1,
            component: .music,
            pythonPath: "acestep-venv/bin/python3",
            executables: ["python": "acestep-venv/bin/python3"],
            isolatedPackages: declaresRealtimeMusic ? ["ace-step", "magenta-rt[mlx]"] : ["ace-step"],
            supportedBackends: [.music],
            capabilities: declaresRealtimeMusic ? ["music-generation", "realtime-music"] : ["music-generation"]
        )
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: url.appendingPathComponent(RuntimeComponent.music.manifestFilename))
    }

    private func makeRuntimeManifest(version: String, compatibilityApi: Int) -> RuntimeManifest {
        RuntimeManifest(
            runtimeVersion: version,
            compatibilityApi: compatibilityApi,
            supportedBackends: RuntimeBackend.allCases
        )
    }

    private func writeExecutableFile(at url: URL) throws {
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: url.path
        )
    }

    private func writeRuntimeChannel(to url: URL, runtimes: [[String: Any]]) throws {
        let data = try runtimeChannelData(runtimes: runtimes)
        try data.write(to: url)
    }

    private func runtimeChannelData(runtimes: [[String: Any]]) throws -> Data {
        let payload: [String: Any] = [
            "schemaVersion": 1,
            "channel": "stable",
            "catalog": [
                "version": "2026.05.09",
                "url": "https://example.com/model-catalog.json",
                "sha256": String(repeating: "1", count: 64),
                "sizeBytes": 1024,
            ],
            "runtimes": runtimes,
        ]
        return try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    }

    private func makeRuntimeAsset(
        version: String,
        platform: String = "macos",
        arch: String = "arm64",
        component: String = "base",
        url: URL? = nil,
        sha256: String = String(repeating: "2", count: 64),
        sizeBytes: Int64 = 2048,
        compatibilityApi: Int = 1,
        minAppVersion: String? = nil
    ) -> [String: Any] {
        var asset: [String: Any] = [
            "version": version,
            "platform": platform,
            "arch": arch,
            "component": component,
            "url": (url ?? URL(string: "https://example.com/runtime-\(version).zip")!).absoluteString,
            "sha256": sha256,
            "sizeBytes": sizeBytes,
            "compatibilityApi": compatibilityApi,
        ]
        if let minAppVersion {
            asset["minAppVersion"] = minAppVersion
        }
        return asset
    }

    private func makeZipArchive(from sourceURL: URL, at archiveURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", sourceURL.path, archiveURL.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw RuntimeUpdateError.unsupportedArchive
        }
    }

    private func archiveSizeBytes(_ url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

}

private final class InstallerCallRecorder {
    var wasCalled = false
}

private final class RuntimeInstallVersionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var installedVersions: [String] = []

    func append(_ version: String) {
        lock.lock()
        installedVersions.append(version)
        lock.unlock()
    }

    func versions() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return installedVersions
    }
}

private final class RuntimeUpdateStateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedStates: [RuntimeUpdateManager.InstallState] = []

    func append(_ state: RuntimeUpdateManager.InstallState) {
        lock.lock()
        recordedStates.append(state)
        lock.unlock()
    }

    func states() -> [RuntimeUpdateManager.InstallState] {
        lock.lock()
        defer { lock.unlock() }
        return recordedStates
    }
}

private struct RuntimeChannelResponse {
    let statusCode: Int
    let data: Data
    let delay: TimeInterval

    init(statusCode: Int, data: Data, delay: TimeInterval = 0) {
        self.statusCode = statusCode
        self.data = data
        self.delay = delay
    }
}

private final class RuntimeChannelURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var statusCode = 200
    private static var responseData = Data()
    private static var routedResponses: [String: RuntimeChannelResponse] = [:]
    private static var requests = 0

    static func reset(statusCode: Int, data: Data) {
        lock.lock()
        self.statusCode = statusCode
        responseData = data
        routedResponses = [:]
        requests = 0
        lock.unlock()
    }

    static func resetRoutes(_ responses: [String: RuntimeChannelResponse]) {
        lock.lock()
        routedResponses = responses
        responseData = Data()
        statusCode = 200
        requests = 0
        lock.unlock()
    }

    static func requestCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "channel.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        Self.lock.lock()
        let routedResponse = Self.routedResponses[url.path]
        let statusCode = routedResponse?.statusCode ?? Self.statusCode
        let data = routedResponse?.data ?? Self.responseData
        let delay = routedResponse?.delay ?? 0
        Self.requests += 1
        Self.lock.unlock()

        let complete = {
            guard let response = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            ) else {
                self.client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }

            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        }

        if delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: complete)
        } else {
            complete()
        }
    }

    override func stopLoading() {}
}

private final class RuntimeArchiveURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var responseData = Data()
    private static var shouldFailFirstRequestAfterFirstChunk = false
    private static var hasFailedFirstRequest = false
    private static var failEveryRequestWithError: URLError?
    private static var rangeHeaders: [String?] = []

    static func reset(
        data: Data,
        failFirstRequestAfterFirstChunk: Bool = false,
        failEveryRequestWith: URLError? = nil
    ) {
        lock.lock()
        responseData = data
        shouldFailFirstRequestAfterFirstChunk = failFirstRequestAfterFirstChunk
        hasFailedFirstRequest = false
        failEveryRequestWithError = failEveryRequestWith
        rangeHeaders = []
        lock.unlock()
    }

    static func recordedRangeHeaders() -> [String?] {
        lock.lock()
        defer { lock.unlock() }
        return rangeHeaders
    }

    static func requestCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return rangeHeaders.count
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "runtime.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let rangeHeader = request.value(forHTTPHeaderField: "Range")
        Self.lock.lock()
        let failEveryRequestWithError = Self.failEveryRequestWithError
        let data = Self.responseData
        let shouldFail = Self.shouldFailFirstRequestAfterFirstChunk
            && !Self.hasFailedFirstRequest
            && rangeHeader == nil
        if shouldFail {
            Self.hasFailedFirstRequest = true
        }
        Self.rangeHeaders.append(rangeHeader)
        Self.lock.unlock()

        if let failEveryRequestWithError {
            client?.urlProtocol(self, didFailWithError: failEveryRequestWithError)
            return
        }

        let startOffset: Int
        if let rangeHeader,
           rangeHeader.hasPrefix("bytes="),
           let rangeStart = rangeHeader
            .dropFirst("bytes=".count)
            .split(separator: "-")
            .first
            .flatMap({ Int($0) }) {
            startOffset = min(max(rangeStart, 0), data.count)
        } else {
            startOffset = 0
        }

        let responseData = Data(data[startOffset...])
        let statusCode = startOffset > 0 ? 206 : 200
        var headers = ["Content-Length": "\(responseData.count)"]
        if startOffset > 0 {
            headers["Content-Range"] = "bytes \(startOffset)-\(data.count - 1)/\(data.count)"
        }

        guard let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: headers
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let firstEnd = responseData.count / 3
        let secondEnd = responseData.count * 2 / 3
        client?.urlProtocol(self, didLoad: Data(responseData.prefix(firstEnd)))
        if shouldFail {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) { [weak self] in
                guard let self else { return }
                self.client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            }
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self else { return }
            self.client?.urlProtocol(self, didLoad: Data(responseData[firstEnd..<secondEnd]))
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.08) { [weak self] in
                guard let self else { return }
                self.client?.urlProtocol(self, didLoad: Data(responseData.suffix(responseData.count - secondEnd)))
                self.client?.urlProtocolDidFinishLoading(self)
            }
        }
    }

    override func stopLoading() {}
}


extension RuntimeError: Equatable {
    public static func == (lhs: RuntimeError, rhs: RuntimeError) -> Bool {
        switch (lhs, rhs) {
        case (.bundleNotFound(let l), .bundleNotFound(let r)) where l == r:
            return true
        case (.pythonNotFound(let l), .pythonNotFound(let r)) where l == r:
            return true
        case (.bridgeScriptNotFound(let l), .bridgeScriptNotFound(let r)) where l == r:
            return true
        case (.runtimeComponentNotFound(let lName, let lPath), .runtimeComponentNotFound(let rName, let rPath)) where lName == rName && lPath == rPath:
            return true
        case (.pythonValidationFailed(let lContext, let lDetails), .pythonValidationFailed(let rContext, let rDetails)) where lContext == rContext && lDetails == rDetails:
            return true
        case (.runtimeUpdateRequired(let lModel, let lVersion), .runtimeUpdateRequired(let rModel, let rVersion)) where lModel == rModel && lVersion == rVersion:
            return true
        case (.initializationFailed(let l), .initializationFailed(let r)) where l == r:
            return true
        default:
            return false
        }
    }
}
