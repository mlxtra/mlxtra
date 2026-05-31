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

        XCTAssertEqual(runtimeManager.estimatedModelSize(modelId: chatProfile.modelId), chatProfile.downloadSizeGB)
        XCTAssertEqual(runtimeManager.estimatedModelSize(modelId: speechProfile.modelId), speechProfile.downloadSizeGB)
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

    func testPreferredRuntimeFallsBackWhenInstalledRuntimeIsMissingAceStepPython() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let installed = root.appendingPathComponent("installed")
        let bundled = root.appendingPathComponent("bundled")
        try makeRuntimeBundle(at: installed, version: "0.2.0")
        try makeRuntimeBundle(at: bundled, version: "0.1.0")
        try FileManager.default.removeItem(at: installed.appendingPathComponent("acestep-venv/bin/python"))

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
        XCTAssertEqual(asset.id, "macos-arm64-0.1.2")
        XCTAssertEqual(manager.availableRuntime, asset)
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
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
    }

    private func makeRuntimeAsset(
        version: String,
        platform: String = "macos",
        arch: String = "arm64",
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
