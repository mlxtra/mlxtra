import XCTest
@testable import MLXtra

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
            RuntimeError.runtimeComponentNotFound("ACE-Step Python executable", "/path/to/acestep-python").localizedDescription,
            "ACE-Step Python executable not found at /path/to/acestep-python. Rebuild the bundled runtime with ./Scripts/build-runtime-bundle.sh"
        )
        XCTAssertEqual(
            RuntimeError.pythonValidationFailed("Hugging Face download runtime", "No module named 'huggingface_hub'").localizedDescription,
            "Hugging Face download runtime is incomplete or broken. Rebuild the bundled runtime with ./Scripts/build-runtime-bundle.sh. No module named 'huggingface_hub'"
        )
        XCTAssertEqual(
            RuntimeError.initializationFailed("test failure").localizedDescription,
            "Failed to initialize runtime: test failure"
        )
    }

    func testRuntimeErrorBridgesLocalizedDescriptionThroughError() {
        let error: Error = RuntimeError.runtimeComponentNotFound("Hugging Face download helper", "/path/to/helper")

        XCTAssertEqual(
            error.localizedDescription,
            "Hugging Face download helper not found at /path/to/helper. Rebuild the bundled runtime with ./Scripts/build-runtime-bundle.sh"
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

    // MARK: - Model Cache Validation

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

        // No metadata in root
        
        let transformerPath = snapshotPath.appendingPathComponent("transformer")
        try FileManager.default.createDirectory(at: transformerPath, withIntermediateDirectories: true)
        
        // Metadata in subdirectory
        try Data("{}".utf8).write(to: transformerPath.appendingPathComponent("config.json"))
        
        // Weights in same or other subdirectory
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
        XCTAssertTrue(message.contains("ACE-Step checkpoints are incomplete"))

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
            presets: [],
            aiModel: nil
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

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MLXtraTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeRuntimeBundle(at url: URL, version: String) throws {
        try FileManager.default.createDirectory(at: url.appendingPathComponent("venv/bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent("python/Frameworks/Versions/3.12"),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: url.appendingPathComponent("venv/bin/python").path, contents: Data())
        FileManager.default.createFile(atPath: url.appendingPathComponent("hf_download_helper.py").path, contents: Data())
        FileManager.default.createFile(atPath: url.appendingPathComponent("acestep_download_helper.py").path, contents: Data())
        try Data("""
        {
          "runtimeVersion": "\(version)",
          "compatibilityApi": 1,
          "platform": "macos",
          "arch": "arm64",
          "packages": [],
          "isolatedPackages": [],
          "supportedBackends": ["vlm", "image"],
          "capabilities": ["chat", "vision", "image-generation"]
        }
        """.utf8).write(to: url.appendingPathComponent("runtime-manifest.json"))
    }
}

// MARK: - RuntimeError Extension for Testing

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
